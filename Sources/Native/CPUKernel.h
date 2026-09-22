#pragma once
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct FurnaceCPU FurnaceCPU;
FurnaceCPU *furnace_cpu_create(void);
void furnace_cpu_destroy(FurnaceCPU *cpu);
void furnace_cpu_start(FurnaceCPU *cpu, int workers);
void furnace_cpu_request_stop(FurnaceCPU *cpu);
void furnace_cpu_join(FurnaceCPU *cpu);
uint64_t furnace_cpu_batches(FurnaceCPU *cpu);
double furnace_cpu_checksum(FurnaceCPU *cpu);
int furnace_cpu_failed(FurnaceCPU *cpu);
double furnace_process_cpu_seconds(void);
uint64_t furnace_memory_bytes(void);
#ifdef __cplusplus
}
#endif

