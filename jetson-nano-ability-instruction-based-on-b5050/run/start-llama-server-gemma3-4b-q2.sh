nohup llama-server -hf unsloth/gemma-3-4b-it-GGUF:Q2_K --n-gpu-layers 99 --port 8776 --host 0.0.0.0 > llama-server-3.log 2>&1 &
