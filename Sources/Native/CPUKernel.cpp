#include "CPUKernel.h"
#include <atomic>
#include <cmath>
#include <thread>
#include <vector>
#include <array>
#include <pthread.h>
#include <mach/mach.h>
#include <sys/resource.h>
#if defined(__aarch64__)
#include <arm_neon.h>
#endif

struct FurnaceCPU {
    std::atomic<bool> stop{true};
    std::atomic<bool> failed{false};
    std::atomic<uint64_t> batches{0};
    std::atomic<double> checksum{0};
    std::vector<std::thread> threads;
};

static void run(FurnaceCPU *cpu, int index) {
    pthread_set_qos_class_self_np(QOS_CLASS_USER_INITIATED, 0);
    uint32_t state = 0x9e3779b9u ^ static_cast<uint32_t>(index + 1);
#if defined(__aarch64__)
    std::array<float32x4_t, 16> lanes;
    for (int n = 0; n < 16; ++n) lanes[n] = vdupq_n_f32(0.01f * (n + 1));
    const auto multiplier = vdupq_n_f32(0.99991f);
    const auto bias = vdupq_n_f32(0.000017f);
#else
    std::array<float, 64> lanes{};
#endif
    while (!cpu->stop.load(std::memory_order_relaxed)) {
        // Independent chains keep SIMD execution units busy without an
        // unbounded accumulation that eventually degenerates to infinity.
        for (int step = 0; step < 4096; ++step) {
            state ^= state << 13; state ^= state >> 17; state ^= state << 5;
#if defined(__aarch64__)
            for (auto &lane : lanes) lane = vfmaq_f32(bias, lane, multiplier);
            lanes[step & 15] = vaddq_f32(lanes[step & 15],
                vdupq_n_f32(static_cast<float>(state & 255) * 0.0000001f));
#else
            for (auto &lane : lanes) lane = std::fma(lane, 0.99991f, 0.000017f);
            lanes[step & 63] += (state & 255) * 0.0000001f;
#endif
        }
        double sum = 0;
#if defined(__aarch64__)
        for (auto lane : lanes) sum += vaddvq_f32(lane);
#else
        for (auto lane : lanes) sum += lane;
#endif
        if (!std::isfinite(sum) || sum <= 0) {
            cpu->failed.store(true); cpu->stop.store(true); break;
        }
        cpu->checksum.store(sum, std::memory_order_relaxed);
        cpu->batches.fetch_add(1, std::memory_order_relaxed);
    }
}

FurnaceCPU *furnace_cpu_create() { return new FurnaceCPU(); }
void furnace_cpu_request_stop(FurnaceCPU *cpu) { cpu->stop.store(true); }
void furnace_cpu_join(FurnaceCPU *cpu) {
    for (auto &thread : cpu->threads) if (thread.joinable()) thread.join();
    cpu->threads.clear();
}
void furnace_cpu_destroy(FurnaceCPU *cpu) {
    if (!cpu) return;
    furnace_cpu_request_stop(cpu); furnace_cpu_join(cpu); delete cpu;
}
void furnace_cpu_start(FurnaceCPU *cpu, int workers) {
    furnace_cpu_request_stop(cpu); furnace_cpu_join(cpu);
    cpu->batches.store(0); cpu->failed.store(false); cpu->checksum.store(0);
    cpu->stop.store(false);
    try {
        for (int i = 0; i < workers; ++i) cpu->threads.emplace_back(run, cpu, i);
    } catch (...) { cpu->failed.store(true); cpu->stop.store(true); }
}
uint64_t furnace_cpu_batches(FurnaceCPU *cpu) { return cpu->batches.load(); }
double furnace_cpu_checksum(FurnaceCPU *cpu) { return cpu->checksum.load(); }
int furnace_cpu_failed(FurnaceCPU *cpu) { return cpu->failed.load() ? 1 : 0; }
double furnace_process_cpu_seconds() {
    rusage usage{};
    if (getrusage(RUSAGE_SELF, &usage) != 0) return 0;
    return usage.ru_utime.tv_sec + usage.ru_stime.tv_sec +
        (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1e6;
}
uint64_t furnace_memory_bytes() {
    task_vm_info_data_t info{};
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, reinterpret_cast<task_info_t>(&info), &count) != KERN_SUCCESS) return 0;
    return info.phys_footprint;
}

