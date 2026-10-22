# 第三方许可

掌声 VoxPalm 的代码按 GPL-3.0-only 开源（见 `LICENSE`）。App 里还带着下面这些第三方组件，按它们各自的许可发布。

## whisper.cpp

- 用途：macOS 26 以下没有系统转写时，内置转写用它把声音转成字。
- 来源：<https://github.com/ggml-org/whisper.cpp>，v1.9.5 官方预编译的 xcframework（构建号 b5454），打包在 `VoxPalm.app/Contents/Frameworks/whisper.framework`。
- 模型不随 App 打包：用户在设置里下载 whisper.cpp 官方在 Hugging Face 上的 ggml 模型（OpenAI Whisper 模型转换而来，MIT 许可）。

```
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```
