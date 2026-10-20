#pragma once
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int (*stix_llama_piece_callback)(const char * bytes, size_t length, void * user_data);

// A null bytes pointer asks the callback whether generation should continue.
void * stix_llama_load(const char * path, uint32_t context_length, char * error, size_t error_length);
uint32_t stix_llama_context_length(void * handle);
int stix_llama_generate(void * handle, const char * messages_json, uint32_t max_tokens, float temperature,
                        stix_llama_piece_callback callback, void * user_data,
                        char * error, size_t error_length);
void stix_llama_unload(void * handle);

#ifdef __cplusplus
}
#endif
