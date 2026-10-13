# HaHa 翻译本地推理运行时

`CHaHaRuntime.xcframework` 是 macOS 15+ / arm64 静态库。应用直接调用 C ABI，不启动 HTTP 服务，不依赖 Python 或 Ollama。当前使用 CPU / ARM NEON，包含 STQ1_0 1.25-bit 与标准 Q4_K_M 支持；未启用 Metal，也不宣称使用 Apple Neural Engine。

## 可复现构建

```sh
brew install cmake
Scripts/build-runtime.sh
```

脚本固定 llama.cpp STQ PR #22836 的提交 `1e411d8f5a1e23525fa3265dfb4bd76265465397`，验证源归档 SHA-256，构建数据保存在 `~/Library/Caches/HaHaTranslateDevelopment/runtime/`。仅最终 XCFramework 和许可证进入项目。采用 `armv8.2-a+dotprod+fp16` 基线，而非针对开发机 M4 的 native 指令集，面向 M1 及后续 Apple Silicon。

`Patches/hy-mt2-legacy-stq.patch` 解决固定官方 1.25-bit 模型的历史类型编号：仅当架构是 `hunyuan-dense`、名称是 `HyMT2 1.8B 2bit Stride16` 且 file_type 为 41 时，把旧 tensor type 42 映射为当前 STQ1_0 43。模型文件原字节和 SHA-256 保持不变；现代 Q2_0 或新版 contiguous STQ 格式不会被此规则冒充支持。默认模型固定为 SHA-256 `cc497fe8f033b52b3b8b00a7669e9661435432f9d4cd43f7ed24400c01507a93`。

Xcode 应链接 `Runtime/CHaHaRuntime.xcframework`、`libc++.tbd` 和 `Accelerate.framework`。静态库不用 embed/sign。

## 运行约定

- 支持获批的 Hy-MT2 dense GGUF 权重；检查架构，模型完整性由下载器验证。
- 单实例串行推理，跨段复用已加载模型及 KV 缓冲区；每段后清除 KV 数据。
- 4096 token 上下文，单次最多 2048 输出 token；达到输出上限会报错，不能把截断内容当成功结果。
- 使用官方 Hy-MT2 单 user 提示格式，不添加 system 消息；源文本中特殊 token 字面值不作为控制 token 解析。
- 官方建议采样配置：temperature 0.7、top_p 0.6、top_k 20、repetition_penalty 1.05。随机种子固定为 42，方便回归；不保证跨硬件逐字一致。
- Swift `onToken` 是增量 UTF-8 片段；生成运行于 detached task，actor 可以及时接收 `cancel()`。独立原子取消对象用于加载、prefill 与生成中断，不会被同步 actor 阻塞。
- `unload()` 取消并等待推理结束后释放权重与缓存。运行时不联网、不记录原文或译文。

## 来源与许可证

- [llama.cpp STQ PR](https://github.com/ggml-org/llama.cpp/pull/22836)
- [固定源提交](https://github.com/ggml-org/llama.cpp/tree/1e411d8f5a1e23525fa3265dfb4bd76265465397)
- [Hy-MT2 官方模型](https://huggingface.co/tencent/Hy-MT2-1.8B)
- [官方聊天模板](https://huggingface.co/tencent/Hy-MT2-1.8B/blob/main/chat_template.jinja)

上游 llama.cpp / ggml、nlohmann JSON、已编译的 Mozilla llamafile，以及 YaRN 和 JSON 附加 MIT 版权通知位于 `Licenses/`，同样复制到应用 `Resources/Licenses/`。未复用 GemmaTrans 代码、未启用 KleidiAI。模型独立遵循其发行许可证，应用需同时展示相应通知。

运行时接口与取消恢复的回归用例位于 [`Tests/`](Tests/)。开源仓库不包含商业发行过程的审核与评估记录；功能测试通过不代表翻译准确率。
