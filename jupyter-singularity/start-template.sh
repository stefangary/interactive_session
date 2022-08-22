echo "$(date): $(hostname):${PWD} $0 $@"

mount_dirs="$(echo  __mount_dirs__ | sed "s|___| |g" | sed "s|__mount_dirs__||g" )"
path_to_sing="__path_to_sing__"
servicePort="__servicePort__"
use_gpus="__use_gpus__"

if [[ ${use_gpus} == "True" ]]; then
    gpu_flag="--nv"
else
    gpu_flag=""
fi


# SANITY CHECKS!
if ! [ -f "${path_to_sing}" ]; then
    echo "ERROR: File $(hostname):${path_to_sing} not found!"
    # FIXME: This error is not always streamed back
    sleep 30
    exit 1
fi

# WEB ADDRESS ISSUES:
# https://github.com/rstudio/rstudio/issues/7953
# https://support.rstudio.com/hc/en-us/articles/200552326-Running-RStudio-Server-with-a-Proxy


singularity run ${gpu_flag} \
    ${mount_dirs} \
    ${path_to_sing} \
    jupyter-notebook \
    --port=$servicePort \
    --ip=0.0.0.0 \
    --NotebookApp.iopub_data_rate_limit=10000000000 \
    --NotebookApp.token= \
    --NotebookApp.password= \
    --no-browser \
    --notebook-dir=~/ \
    --NotebookApp.tornado_settings="{'static_url_prefix':'/${FORWARDPATH}/${IPADDRESS}/${openPort}/static/'}" \
    --NotebookApp.base_url="/${FORWARDPATH}/${IPADDRESS}/${openPort}/" \
    --NotebookApp.allow_origin=*
