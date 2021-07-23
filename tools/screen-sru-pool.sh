#!/bin/bash
set -x
OUT=$PWD

target_img="no_provision"
n_machine=10
occupy_time="10"
ssh_key="#"
usage() {
cat << EOF
usage:
$0 [--out <folder>] --img <img name> options
$0 [--out <folder>] --list-img

    -h|--help print this message
    --check-queue deploy input queue ID and upload the report
    --out the folder put the generated report. the default is \$PWD
    -n|--number-machine How many machines you would like to screen. The default is 10.
    --img select which image to provision. Give "no_provision" will skip the provision.
    --list-img list avaliable images for certification pool.

        e.g. $0 --out test --list-img

    --time how many mins you plan to occupy. Default is 10.
    --ssh-key the key from which lp account that you would like to put on target machine. e.g. lp:alextu

EOF
exit 0
}

prepare_env(){
    testflinger-cli list-queues > "$OUT"/sru-pool-queue-list
}

commit_artifacts(){
    # put worked queue to git repository
    echo "commit"
}

clear_env(){
    echo "clear"
}

process_queue(){
    queue_id="$1"
    if [ "$ssh_key" != "#" ]; then
        ssh_key="- $ssh_key"
    fi
    # provision each queue.

cat << EOF > "$OUT"/"$queue_id".yaml
job_queue: $queue_id
reserve_data:
  ssh_keys:
    - lp:alextu
    $ssh_key
  timeout: $occupy_time
test_data:
  test_cmds: |
    set -x
    SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"
    _run() {{
        ssh -t $SSH_OPTS ubuntu@\$DEVICE_IP "\$@"
    }}

    _run lsb_release -a
    _run ip a
    _run lspci -nnk
    _run lsusb
EOF
    if [ "$target_img" != "no_provision" ]; then
        echo "provision_data:" >> "$OUT"/"$queue_id".yaml
        echo "  distro: $target_img" >> "$OUT"/"$queue_id".yaml
    fi
    cat "$OUT"/"$queue_id".yaml
    JOB=$(testflinger-cli submit "$OUT"/"$queue_id".yaml | grep job_id | cut -d' ' -f2);
    echo "\$ testflinger-cli poll $JOB" > "$OUT"/"$queue_id".log
    echo "" >> "$OUT"/"$queue_id".log
    testflinger-cli poll "$JOB" >> "$OUT"/"$queue_id".poll
    testflinger-cli results "$JOB" >> "$OUT"/"$queue_id".results
}

screen_result() {
    set -x
    provision_results="$OUT"/"$1".results
    local status_to_check
    #while read -r provision_results; do
    if [ "$target_img" = "no_provision" ]; then
        status_to_check="test_status"
        echo "screening $provision_results"
        if [ "0" == "$(jq '{test_status} | .[]' < "$provision_results")" ]; then
            basename "$provision_results"| cut -d '.' -f 1 >> "$OUT"/worked_queues
            jq '{reserve_output} | .[]' < "$provision_results" | sed 's|\\n|\n|g' | sed 's|\\"|\n|g' | grep 'trictHostKeyChecking' >> "$OUT"/worked_queues
            echo "" >> "$OUT"/worked_queues
        else
            echo "failed"
        fi
    else
        status_to_check="provision_status"
        echo "screening $provision_results"
        if [ "0" == "$(jq '{provision_status} | .[]' < "$provision_results")" ]; then
            basename "$provision_results"| cut -d '.' -f 1 >> "$OUT"/worked_queues
        else
            echo "failed"
        fi
    fi
    #done < <(find "$OUT" -name "*.results")
    set +x
}

# $1 : error code
# $2 : error message
error(){
    echo "[ERROR] ""$2"
    return "$1"
}

list_all_imgs() {
    local test_q
    if [ -f "$OUT"/all-imgs.list ]; then
        cat "$OUT"/all-imgs.list
        return
    fi
    if [ ! -f "$OUT"/sru-pool-queue-list ]; then
        prepare_env
    fi
    test_q="$(grep 2020 "$OUT"/sru-pool-queue-list -m1 | awk '{print $1}')"
    wget --directory-prefix="$OUT" https://raw.githubusercontent.com/alex-tu-cc/testflinger-cookbook/master/examples/deploy-img-template1.yaml
    yq w "$OUT"/deploy-img-template1.yaml 'job_queue' "$test_q" > "$OUT"/tmp-list-img.yaml
    yq w "$OUT"/tmp-list-img.yaml 'provision_data.distro' "non-exist-img-$RANDOM" > "$OUT"/list-img.yaml
    cat "$OUT"/list-img.yaml
    export YAML="$OUT"/list-img.yaml; JOB=$(testflinger-cli submit $YAML | grep job_id | cut -d' ' -f2);echo "$JOB";testflinger-cli poll "$JOB" | sed 's/,/\n/g' | grep custom/ | sed 's/custom\///g' | tee "$OUT"/all-imgs.list
}

main() {
    while [ $# -gt 0 ]
    do
        case "$1" in
            -h | --help)
                usage 0
                exit 0
                ;;
            --out)
                shift
                OUT="$1";
                ;;
            --check-queue)
                shift
                [ -n "$1" ] || error 1 "invalid QUEUE_ID"
                process_queue "$1"
                screen_result "$1"
                return 0
                ;;
            -n|--number-machine)
                shift
                n_machine=$1
                ;;
            --img)
                shift
                target_img="$1"
                ;;
            --list-img)
                list_all_imgs
                exit 0
                ;;
            --time)
                shift
                occupy_time="$1"
                ;;
            --ssh-key)
                shift
                ssh_key="$1"
                ;;
            *)
            usage
           esac
           shift
    done

    prepare_env
    count=0
    while read -r queue; do
        count=$((count+1))
        [ "$count" -le "$n_machine" ] || break
        ($0 --out "$OUT" --img $target_img --time $occupy_time --ssh-key $ssh_key --check-queue "$queue" &)
    done < <(grep -E "^ [[:digit:]]{6}-[[:digit:]]{5}" "$OUT"/sru-pool-queue-list | grep -v Lenovo | grep -v HP | awk '{print $1}' | sort -r)
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi


