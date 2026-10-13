#include "CHaHaRuntime.h"
#include <iostream>
#include <string>
#include <vector>
int main(int argc, char ** argv) {
    if (argc < 2) return 64;
    const std::vector<std::string> prompts = {
        "Translate the following text from German into English. Note that you should only output the translated result without any additional explanation:\n\nGift",
        "Translate the following German text into English. Note that you should only output the translated result without any additional explanation:\n\nGift",
        "Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n\nGerman text:\nGift",
        "Translate the following text into English. The source text is written in German; interpret words in German rather than guessing the source language. Note that you should only output the translated result without any additional explanation:\n\nGift",
        "将以下德语文本翻译成英语，注意只需要输出翻译后的结果，不要额外解释：\n\nGift",
        "Translate from German to English:\nGift",
        "Translate the following German text into English. The source language is German. Note that you should only output the translated result without any additional explanation:\n\nGift",
        "The source language is German.\n\nTranslate the following German text into English. Note that you should only output the translated result without any additional explanation:\n\nGift",
        "Translate the following German text into English. Note that you should only output the translated result without any additional explanation:\n\nGerman text:\nGift",
        "Translate the following German text into English. Interpret words according to their German meaning. Note that you should only output the translated result without any additional explanation:\n\nGift",
        "Translate the following text into English. Note that you should only output the translated result without any additional explanation:\n\n[German] Gift",
        "Translate the following text into English. The original language is German, not English. Note that you should only output the translated result without any additional explanation:\n\nGift"
    };
    auto engine = haha_engine_create();
    for (int a = 1; a < argc; ++a) {
        for (size_t p = 0; p < prompts.size(); ++p) {
            auto cancel = haha_cancellation_create();
            char * output = nullptr, * error = nullptr;
            haha_metrics metrics{};
            int status = haha_engine_translate(engine, argv[a], prompts[p].c_str(), 100, cancel, nullptr, nullptr, &output, &error, &metrics);
            std::cout << "MODEL " << argv[a] << "\nVARIANT " << p + 1 << "\nPROMPT " << prompts[p] << "\nSTATUS " << status << "\nOUTPUT " << (output ? output : "") << "\nERROR " << (error ? error : "") << "\n" << std::flush;
            haha_string_free(output); haha_string_free(error); haha_cancellation_destroy(cancel);
        }
        haha_engine_unload(engine);
    }
    haha_engine_destroy(engine);
}
