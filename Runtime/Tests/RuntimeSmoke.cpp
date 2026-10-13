#include "CHaHaRuntime.h"
#include <atomic>
#include <chrono>
#include <iostream>
#include <string>
#include <thread>

struct Stream { std::string text; size_t chunks = 0; };
static void token(const char * bytes, size_t length, void * pointer) {
    auto & stream = *static_cast<Stream *>(pointer);
    stream.text.append(bytes, length);
    ++stream.chunks;
}
static bool run(haha_engine * engine, const char * model, const std::string & prompt,
                int limit, int expected, bool cancel_during = false) {
    auto cancel = haha_cancellation_create();
    std::thread canceller;
    if (cancel_during) canceller = std::thread([cancel] {
        std::this_thread::sleep_for(std::chrono::milliseconds(30));
        haha_cancellation_request(cancel);
    });
    char * output = nullptr, * error = nullptr;
    haha_metrics metrics{};
    Stream stream;
    auto start = std::chrono::steady_clock::now();
    int status = haha_engine_translate(engine, model, prompt.c_str(), limit, cancel,
                                      token, &stream, &output, &error, &metrics);
    double seconds = std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
    if (canceller.joinable()) canceller.join();
    std::cout << "status=" << status << " expected=" << expected << " seconds=" << seconds
              << " load=" << metrics.load_seconds << " first_token=" << metrics.first_token_seconds
              << " prompt_tokens=" << metrics.prompt_tokens << " generated_tokens=" << metrics.generated_tokens
              << " chunks=" << stream.chunks << '\n';
    if (output) std::cout << "TRANSLATION: " << output << '\n';
    if (error) std::cout << "ERROR: " << error << '\n';
    bool ok = status == expected;
    if (status == HAHA_OK) ok = ok && output && stream.text == output && !stream.text.empty();
    if (status != HAHA_OK) ok = ok && output == nullptr;
    if (cancel_during) ok = ok && seconds < 3.0;
    haha_string_free(output);
    haha_string_free(error);
    haha_cancellation_destroy(cancel);
    return ok;
}
int main(int argc, char ** argv) {
    if (argc != 2) return 64;
    std::cout << haha_runtime_version() << '\n';
    auto engine = haha_engine_create();
    bool ok = engine != nullptr;
    if (!ok) return 1;
    ok &= run(engine, argv[1], "Translate the following text into Chinese. Note that you should only output the translated result without any additional explanation:\n\nThe meeting starts at 10:30 tomorrow. Please bring the 2026 budget report.", 256, HAHA_OK);
    ok &= run(engine, argv[1], "Reference the following translations:\n工作区 translates to workspace\n\nTranslate the following text into English. Note that you should only output the translated result without any additional explanation:\n\n请在工作区中保存文件，价格是 99.50 元。", 256, HAHA_OK);
    ok &= run(engine, argv[1], "Translate the following text into Chinese, without additional explanation:\nThe meeting starts at ten tomorrow.", 1, HAHA_OUTPUT_LIMIT);
    std::string long_text = "Translate the following text into Chinese, without additional explanation:\n";
    for (int i = 0; i < 100; ++i) long_text += "This sentence is intentionally repeated to test cancellation during prompt processing. ";
    ok &= run(engine, argv[1], long_text, 1000, HAHA_CANCELLED, true);
    // A cancelled decode must leave the cached engine reusable.
    ok &= run(engine, argv[1], "Translate the following text into English, without additional explanation:\n今天下午三点见。", 128, HAHA_OK);
    haha_engine_unload(engine);
    haha_engine_destroy(engine);
    std::cout << (ok ? "PASS" : "FAIL") << '\n';
    return ok ? 0 : 1;
}
