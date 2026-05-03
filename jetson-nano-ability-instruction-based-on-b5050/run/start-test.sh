rllama-cli -hf unsloth/gemma-3-4b-it-GGUF:Q2_K --n-gpu-layers 99
rllama-cli -hf unsloth/Qwen3.5-0.8B-GGUF:UD-Q4_K_XL --n-gpu-layers 99 --reasoning-budget 128
rllama-cli -hf unsloth/Qwen3.5-2B-GGUF:UD-IQ2_XXS --n-gpu-layers 99 --reasoning-budget 64
rllama-cli -hf unsloth/Qwen3.5-2B-GGUF:UD-IQ2_M --n-gpu-layers 99 --reasoning-budget 0
#[ Prompt: 24,6 t/s | Generation: 6,2 t/s ]
rllama-cli -hf unsloth/Qwen3.5-0.8B-GGUF:Q8_0 --n-gpu-layers 99
