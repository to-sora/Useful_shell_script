# build_vulkan_gpu.sh

Rebuild `llama.cpp` for Vulkan GPU acceleration using a locally installed Vulkan SDK, with CUDA explicitly disabled.

## Requirements
- A Vulkan SDK installed at `~/vulkan/1.4.349.0`
- Vulkan environment script at `~/vulkan/1.4.349.0/setup-env.sh`
- A `llama.cpp` checkout at `~/llama_cpp_iGPU`
- `cmake` and a working C/C++ build toolchain

## Usage
```bash
bash build_vulkan_gpu.sh
```

## Notes
- The script removes the existing `~/llama_cpp_iGPU/build-vk` directory before configuring a fresh build.
- It enables `GGML_VULKAN` and disables `GGML_CUDA`.
- Vulkan include and library paths are taken from `$VULKAN_SDK` after sourcing the SDK setup script.
- Paths and SDK version are hard-coded; edit the script if your Vulkan SDK or `llama.cpp` checkout is stored elsewhere.
- The final build runs in parallel with `cmake --build ... -j`.
