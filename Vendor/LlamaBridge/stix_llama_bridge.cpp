#include "stix_llama_bridge.h"
#include "llama.h"
#include "json.hpp"

#include <algorithm>
#include <cstring>
#include <memory>
#include <mutex>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
using json = nlohmann::json;

struct Session {
    llama_model * model = nullptr;
    llama_context * context = nullptr;
    std::mutex mutex;
    ~Session() {
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
};

void fail(char * error, size_t length, const std::string & message) {
    if (!error || length == 0) return;
    std::strncpy(error, message.c_str(), length - 1);
    error[length - 1] = '\0';
}

std::string format_messages(Session & session, const char * messages_json) {
    const auto parsed = json::parse(messages_json);
    if (!parsed.is_array() || parsed.empty() || parsed.size() > 512) {
        throw std::runtime_error("Invalid chat messages");
    }
    std::vector<std::string> roles, contents;
    roles.reserve(parsed.size());
    contents.reserve(parsed.size());
    for (const auto & item : parsed) {
        if (!item.is_object() || !item.contains("role") || !item.contains("content") ||
            !item["role"].is_string() || !item["content"].is_string()) {
            throw std::runtime_error("Invalid chat message");
        }
        auto role = item["role"].get<std::string>();
        auto content = item["content"].get<std::string>();
        if (role != "system" && role != "user" && role != "assistant") {
            throw std::runtime_error("Unsupported chat role");
        }
        roles.push_back(std::move(role));
        contents.push_back(std::move(content));
    }
    std::vector<llama_chat_message> messages;
    messages.reserve(roles.size());
    for (size_t index = 0; index < roles.size(); index++) {
        messages.push_back({roles[index].c_str(), contents[index].c_str()});
    }
    const char * chat_template = llama_model_chat_template(session.model, nullptr);
    if (!chat_template) throw std::runtime_error("GGUF model has no supported chat template");
    int32_t needed = llama_chat_apply_template(chat_template, messages.data(), messages.size(), true, nullptr, 0);
    if (needed <= 0 || needed > 8'000'000) throw std::runtime_error("Unsupported or oversized chat template");
    std::string prompt(static_cast<size_t>(needed) + 1, '\0');
    const int32_t written = llama_chat_apply_template(chat_template, messages.data(), messages.size(), true,
                                                       prompt.data(), static_cast<int32_t>(prompt.size()));
    if (written != needed) throw std::runtime_error("Could not format model prompt");
    prompt.resize(static_cast<size_t>(written));
    return prompt;
}
}

extern "C" void * stix_llama_load(const char * path, uint32_t context_length, char * error, size_t error_length) {
    try {
        if (!path || context_length < 512 || context_length > 131072) throw std::runtime_error("Invalid model path or context limit");
        static std::once_flag backend_once;
        std::call_once(backend_once, [] { llama_backend_init(); });
        auto session = std::make_unique<Session>();
        auto model_params = llama_model_default_params();
        model_params.n_gpu_layers = 99;
        session->model = llama_model_load_from_file(path, model_params);
        if (!session->model) throw std::runtime_error("Failed to load GGUF model");
        auto context_params = llama_context_default_params();
        context_params.n_ctx = context_length;
        context_params.n_batch = 512;
        context_params.n_ubatch = 512;
        context_params.n_threads = 4;
        context_params.n_threads_batch = 4;
        session->context = llama_init_from_model(session->model, context_params);
        if (!session->context) throw std::runtime_error("Failed to initialize model context");
        return session.release();
    } catch (const std::exception & exception) {
        fail(error, error_length, exception.what());
        return nullptr;
    }
}

extern "C" uint32_t stix_llama_context_length(void * handle) {
    if (!handle) return 0;
    return llama_n_ctx(static_cast<Session *>(handle)->context);
}

extern "C" int stix_llama_generate(void * handle, const char * messages_json, uint32_t max_tokens,
                                   stix_llama_piece_callback callback, void * user_data,
                                   char * error, size_t error_length) {
    try {
        if (!handle || !messages_json || !callback || max_tokens == 0 || max_tokens > 32768) {
            throw std::runtime_error("Invalid generation request");
        }
        auto & session = *static_cast<Session *>(handle);
        std::lock_guard lock(session.mutex);
        const auto prompt = format_messages(session, messages_json);
        const auto * vocab = llama_model_get_vocab(session.model);
        const int32_t context_length = static_cast<int32_t>(llama_n_ctx(session.context));
        std::vector<llama_token> tokens(static_cast<size_t>(context_length) + 1);
        int32_t count = llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
                                       tokens.data(), static_cast<int32_t>(tokens.size()), true, true);
        if (count <= 0 || count >= context_length) throw std::runtime_error("Prompt exceeds the model context window");
        if (count + static_cast<int32_t>(max_tokens) > context_length) {
            throw std::runtime_error("Prompt and response reserve exceed the model context window");
        }
        llama_memory_clear(llama_get_memory(session.context), true);
        for (int32_t offset = 0; offset < count; offset += 512) {
            if (!callback(nullptr, 0, user_data)) throw std::runtime_error("Generation cancelled");
            const auto length = std::min<int32_t>(512, count - offset);
            if (llama_decode(session.context, llama_batch_get_one(tokens.data() + offset, length)) != 0) {
                throw std::runtime_error("Prompt evaluation failed");
            }
        }
        auto * sampler = llama_sampler_chain_init(llama_sampler_chain_default_params());
        if (!sampler) throw std::runtime_error("Could not initialize sampler");
        llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.9f, 1));
        llama_sampler_chain_add(sampler, llama_sampler_init_temp(0.7f));
        llama_sampler_chain_add(sampler, llama_sampler_init_dist(12345));
        int produced = 0;
        try {
            for (uint32_t step = 0; step < max_tokens; step++) {
                if (!callback(nullptr, 0, user_data)) throw std::runtime_error("Generation cancelled");
                const auto token = llama_sampler_sample(sampler, session.context, -1);
                llama_sampler_accept(sampler, token);
                if (llama_vocab_is_eog(vocab, token)) break;
                char buffer[512];
                int32_t length = llama_token_to_piece(vocab, token, buffer, sizeof(buffer), 0, false);
                if (length < 0) {
                    std::vector<char> larger(static_cast<size_t>(-length));
                    length = llama_token_to_piece(vocab, token, larger.data(), static_cast<int32_t>(larger.size()), 0, false);
                    if (length < 0 || !callback(larger.data(), static_cast<size_t>(length), user_data)) {
                        throw std::runtime_error("Generation cancelled or token decoding failed");
                    }
                } else if (!callback(buffer, static_cast<size_t>(length), user_data)) {
                    throw std::runtime_error("Generation cancelled");
                }
                produced++;
                llama_token next = token;
                if (step + 1 < max_tokens && llama_decode(session.context, llama_batch_get_one(&next, 1)) != 0) {
                    throw std::runtime_error("Token evaluation failed");
                }
            }
        } catch (...) {
            llama_sampler_free(sampler);
            throw;
        }
        llama_sampler_free(sampler);
        return produced;
    } catch (const std::exception & exception) {
        fail(error, error_length, exception.what());
        return -1;
    }
}

extern "C" void stix_llama_unload(void * handle) {
    delete static_cast<Session *>(handle);
}
