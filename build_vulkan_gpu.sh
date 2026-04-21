cd ~/vulkan
source ~/vulkan/1.4.349.0/setup-env.sh

cd ~/llama_cpp_iGPU
rm -rf build-vk
cmake -B build-vk \
  -DGGML_VULKAN=1 \
  -DGGML_CUDA=OFF \
  -DCMAKE_PREFIX_PATH="$VULKAN_SDK" \
  -DVulkan_INCLUDE_DIR="$VULKAN_SDK/include" \
  -DVulkan_LIBRARY="$VULKAN_SDK/lib/libvulkan.so"
cmake --build build-vk --config Release -j
