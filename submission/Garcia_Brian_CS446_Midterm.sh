#!/usr/bin/env bash
# ============================================================================
# CS 446 Midterm - OpenCSUSM
# Name: Brian Garcia
# Campus ID: 201213277
# Lane: gpu                           
# ============================================================================
#
# WHY I CHOSE THIS LANE
# I selected the gpu lane for this deployment to leverage hardware acceleration for LLM inference.
# While the cpu lane is an alternative, the gpu lane utilizing the g6f.large instance provides the necessary CUDA support to run vLLM efficiently.
# Furthermore, GPU instances have specific vCPU service quotas that must be verified beforehand to ensure successful launching compared to standard CPU limits.
# The g6f.large instance costs approximately $0.54 per hour in US East (N. Virginia), which translates to roughly 185 hours of compute within a $100 budget.
# For model selection, I am serving the Qwen/Qwen2.5-0.5B-Instruct model because its compact size ensures rapid startup times and minimal memory footprint.
# This small model is the optimal choice for this test as it fits comfortably within the allocated GPU memory utilization limits while delivering fast response times.
#
# ============================================================================

set -euo pipefail

# --------------------------- MY CHOICES -------------------------------
REGION="${REGION:-us-east-1}"
OWNER="${OWNER:-garcia}"             # your last name, lower case
KEY_NAME="${KEY_NAME:-}"          # Auto-detect an existing AWS EC2 key pair if unset
INSTANCE="g6f.large"               # g4dn.xlarge or c7i.2xlarge
RATE="0.54"                        # the on-demand hourly rate you assume
PORT="8000"                        # 8000 for vLLM, 11434 for Ollama
MODEL="Qwen/Qwen2.5-0.5B-Instruct"   # Qwen/Qwen2.5-0.5B-Instruct or qwen2.5:0.5b
# No custom EBS volume configuration is used for this assignment.

# Mappings for operational script compatibility
export REGION
export INSTANCE_TYPE="$INSTANCE"
export MODEL="$MODEL"
export API_PORT="$PORT"
export SSH_PORT="22"
export INSTANCE_NAME="open CSUSM"
export OWNER="$OWNER"
export KEY_NAME

# AWS DLAMI: current Amazon Linux 2023 image with NVIDIA driver/CUDA support
# and explicit support for g6f in the current release family.
export DLAMI_PARAMETER="/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"

STATE_DIR="${STATE_DIR:-$HOME/.opencsusm}"
STATE_FILE="$STATE_DIR/state.env"

# ------------------------------ helpers -------------------------------------
# Terminate execution immediately and print an error message to standard error.
die() {
    echo "ERROR: $*" >&2
    exit 1
}

# Verify that a required command executable exists in the system path.
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

# Check that local prerequisite CLI tools are installed before running deployment actions.
check_local_prereqs() {
    need_cmd aws
    need_cmd ssh
    need_cmd curl
}

# Query AWS STS to retrieve and display the active caller identity details.
aws_identity() {
    aws sts get-caller-identity \
        --query '{Account:Account,Arn:Arn,UserId:UserId}' \
        --output table
}

# Fetch the external public IP address of the local machine using an external service.
get_public_ip() {
    curl -4 -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]'
}

# Determine and validate the EC2 key pair name to be used for instance access.
get_key_name() {
    if [[ -n "${KEY_NAME:-}" ]]; then
        echo "$KEY_NAME"
        return
    fi

    mapfile -t keys < <(
        aws ec2 describe-key-pairs \
            --region "$REGION" \
            --query 'KeyPairs[].KeyName' \
            --output text | tr '\t' '\n' | sed '/^$/d'
    )

    if [[ "${#keys[@]}" -eq 0 ]]; then
        die "No EC2 key pair exists in $REGION. Create one in EC2 first."
    elif [[ "${#keys[@]}" -eq 1 ]]; then
        KEY_NAME="${keys[0]}"
        export KEY_NAME
        echo "$KEY_NAME"
        return
    fi

    echo "More than one EC2 key pair exists in $REGION:" >&2
    printf '  %s\n' "${keys[@]}" >&2
    read -r -p "Enter the KEY_NAME to use: " KEY_NAME
    [[ -n "$KEY_NAME" ]] || die "KEY_NAME cannot be empty."
    export KEY_NAME
    echo "$KEY_NAME"
}

# Locate the local filesystem path of the SSH private key .pem file.
get_key_path() {
    if [[ -n "${KEY_PATH:-}" ]]; then
        echo "$KEY_PATH"
        return
    fi

    local candidate="$HOME/.ssh/${KEY_NAME}.pem"
    if [[ -f "$candidate" ]]; then
        KEY_PATH="$candidate"
        export KEY_PATH
        echo "$KEY_PATH"
        return
    fi

    echo
    echo "The key pair exists in AWS, but this private key was not found at:"
    echo "  $candidate"
    read -r -p "Enter the full path to your .pem private key: " KEY_PATH
    [[ -f "$KEY_PATH" ]] || die "Private key not found: $KEY_PATH"
    export KEY_PATH
    echo "$KEY_PATH"
}

# Load and source saved deployment state variables from the local state file.
load_state() {
    [[ -f "$STATE_FILE" ]] || die "ERROR:No local deployment state. Run stage 2 first."
    # shellcheck disable=SC1090
    source "$STATE_FILE"

    : "${INSTANCE_ID:?Missing INSTANCE_ID in state}"
    : "${KEY_NAME:?Missing KEY_NAME in state}"
    : "${KEY_PATH:?Missing KEY_PATH in state}"
    : "${SG_ID:?Missing SG_ID in state}"
    : "${SSH_USER:?Missing SSH_USER in state}"
    : "${PUBLIC_IP:?Missing PUBLIC_IP in state}"
    : "${DNS_NAME:?Missing DNS_NAME in state}"
}

# Poll the remote instance over SSH until the connection successfully responds.
wait_for_ssh() {
    local i
    for i in $(seq 1 60); do
        if ssh -i "$KEY_PATH" \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=5 \
            "$SSH_USER@$DNS_NAME" "true" >/dev/null 2>&1; then
            return 0
        fi
        sleep 5
    done
    die "SSH did not become available at $DNS_NAME"
}

# ============================================================================
# PART 2 - THE COMMANDS
# ============================================================================

# ------------------------------ Stage 1 -------------------------------------
stage1() {
    # Verify that all required local CLI utilities are installed and available.
    check_local_prereqs

    # Print a formatted header banner to identify stage 1 execution.
    echo "============================================================"
    echo "STAGE 1 - quota + live price + capacity"
    echo "============================================================"
    echo
    # Print an informational label for IAM identity output.
    echo "AWS identity:"
    # Retrieve and display the active AWS IAM caller identity details.
    aws_identity
    echo
    #AWS deployment region.
    echo "Region       : $REGION"
    #EC2 instance type.
    echo "Instance     : $INSTANCE_TYPE"
    #model identifier.
    echo "Model        : $MODEL"
    #API port number noting it remains closed in the security group.
    echo "API port     : $API_PORT (NOT opened in Security Group)"
    #SSH administration port number.
    echo "SSH port     : $SSH_PORT"
    echo

    # Print section header for vCPU service quota verification.
    echo "1A. Running On-Demand G/VT quota:"
    # Query the AWS Service Quotas API to retrieve the account limit for G and VT instances.
    quota_json="$(
        aws service-quotas list-service-quotas \
            --service-code ec2 \
            --region "$REGION" \
            --query "Quotas[?contains(QuotaName, 'Running On-Demand G and VT instances')]" \
            --output json
    )"
    # Output the raw JSON quota query result.
    echo "$quota_json"

    # Extract the numeric vCPU quota value from the JSON response using Python.
    quota_value="$(
        printf '%s' "$quota_json" |
        python3 -c 'import json,sys; x=json.load(sys.stdin); print(x[0]["Value"] if x else "UNKNOWN")' \
        2>/dev/null || echo "UNKNOWN"
    )"
    # Display the applied vCPU quota limit.
    echo "Applied G/VT vCPU quota: $quota_value"
    # vCPU requirement for the g6f.large instance type.
    echo "g6f.large requires 2 vCPUs."

    echo
    #header for regional instance availability check.
    echo "1B. g6f.large regional availability:"
    # Query EC2 instance offerings to check in which availability zones g6f.large is offered.
    aws ec2 describe-instance-type-offerings \
        --region "$REGION" \
        --location-type availability-zone \
        --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
        --query 'sort_by(InstanceTypeOfferings,&Location)[].Location' \
        --output text

    echo
    #header for AWS Price List API lookup.
    echo "1C. Live AWS Price List API lookup:"
    # Query the AWS Price List API for live on-demand hourly pricing of the instance.
    if price_json="$(
        aws pricing get-products \
            --region us-east-1 \
            --service-code AmazonEC2 \
            --filters \
                Type=TERM_MATCH,Field=instanceType,Value="$INSTANCE_TYPE" \
                Type=TERM_MATCH,Field=operatingSystem,Value=Linux \
                Type=TERM_MATCH,Field=preInstalledSw,Value=NA \
                Type=TERM_MATCH,Field=tenancy,Value=Shared \
                Type=TERM_MATCH,Field=capacitystatus,Value=Used \
                Type=TERM_MATCH,Field=location,Value="US East (N. Virginia)" \
            --max-results 20 \
            --output json 2>/dev/null
    )"; then
        # Parse the pricing JSON output using Python to extract the hourly cost.
        python3 - "$price_json" <<'PY'
import json, sys
data = json.loads(sys.argv[1])
found = False
for raw in data.get("PriceList", []):
    p = json.loads(raw)
    terms = p.get("terms", {}).get("OnDemand", {})
    for term in terms.values():
        for dim in term.get("priceDimensions", {}).values():
            price = dim.get("pricePerUnit", {}).get("USD")
            if price:
                print(f"g6f.large US East (N. Virginia) On-Demand: ${price}/hour")
                found = True
                raise SystemExit(0)
if not found:
    print("Price List API returned no matching price for this query.")
    print("Run stage 1 again if AWS pricing metadata has not propagated.")
PY
    else
        # Fallback message if the pricing API lookup encounters an error.
        echo "Price List API lookup failed."
        echo "This does NOT affect deployment; rerun stage 1 for a fresh price lookup."
    fi

    echo
    # Confirmation that stage 1 execution has finished.
    echo "STAGE 1 COMPLETE."
    # Important reminder regarding vCPU quota prerequisites.
    echo "IMPORTANT: Do not launch until the G/VT quota is >= 2 vCPUs and the instance"
    echo "type is offered in at least one Availability Zone."
}

# ------------------------------ Stage 2 -------------------------------------
stage2() {
    # Verify local prerequisites before initiating resource deployment.
    check_local_prereqs
    # Create the local state directory to store deployment identifiers.
    mkdir -p "$STATE_DIR"

    # Print a formatted header banner for stage 2.
    echo "============================================================"
    echo "STAGE 2 - launch open CSUSM"
    echo "============================================================"
    echo

    # Display current IAM identity details.
    aws_identity
    echo

    # Query AWS STS to capture the current AWS account ID for resource naming.
    ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
    # Fetch the local machine external public IP address.
    PUBLIC_IP="$(get_public_ip)"
    # Determine the name of the EC2 key pair to use.
    KEY_NAME="$(get_key_name)"
    # Locate the physical SSH private key file path.
    KEY_PATH="$(get_key_path)"

    # Print section header for deployment configuration summary.
    echo
    echo "Using:"
    # Print the retrieved AWS account ID.
    echo "  Account     : $ACCOUNT"
    # Print the deployment region.
    echo "  Region      : $REGION"
    # Print the instance type.
    echo "  Instance    : $INSTANCE_TYPE"
    # Print the key pair name.
    echo "  Key pair    : $KEY_NAME"
    # Print the authorized SSH source CIDR block.
    echo "  SSH source  : $PUBLIC_IP/32"
    echo

    # Query EC2 to locate the default VPC identifier in the target region.
    VPC_ID="$(
        aws ec2 describe-vpcs \
            --region "$REGION" \
            --filters Name=is-default,Values=true \
            --query 'Vpcs[0].VpcId' \
            --output text
    )"

    # Check if a default VPC exists, and create one automatically if missing.
    if [[ "$VPC_ID" == "None" || -z "$VPC_ID" ]]; then
        # Print an informational message regarding VPC creation.
        echo "No default VPC found in $REGION. Creating one automatically..."
        # Request AWS to provision a default VPC in the region.
        aws ec2 create-default-vpc --region "$REGION" >/dev/null
        
        # Re-fetch the newly created default VPC identifier.
        VPC_ID="$(
            aws ec2 describe-vpcs \
                --region "$REGION" \
                --filters Name=is-default,Values=true \
                --query 'Vpcs[0].VpcId' \
                --output text
        )"
    fi

    # Terminate execution if a valid VPC ID cannot be found or created.
    [[ "$VPC_ID" != "None" && -n "$VPC_ID" ]] ||
        die "Failed to create or find a default VPC in $REGION."

    # Retrieve all availability zones offering the g6f instance type.
    mapfile -t OFFERED_AZS < <(
        aws ec2 describe-instance-type-offerings \
            --region "$REGION" \
            --location-type availability-zone \
            --filters "Name=instance-type,Values=$INSTANCE_TYPE" \
            --query 'sort_by(InstanceTypeOfferings,&Location)[].Location' \
            --output text | tr '\t' '\n' | sed '/^$/d'
    )
    # Ensure at least one availability zone offers the instance type.
    [[ "${#OFFERED_AZS[@]}" -gt 0 ]] ||
        die "$INSTANCE_TYPE is not offered in any AZ in $REGION."

    SUBNET_ID=""
    AZ=""
    # Iterate through offered availability zones to find a valid default subnet.
    for az in "${OFFERED_AZS[@]}"; do
        # Query EC2 subnets matching the VPC and availability zone.
        candidate="$(
            aws ec2 describe-subnets \
                --region "$REGION" \
                --filters \
                    "Name=vpc-id,Values=$VPC_ID" \
                    "Name=availability-zone,Values=$az" \
                    "Name=default-for-az,Values=true" \
                --query 'Subnets[0].SubnetId' \
                --output text
        )"
        if [[ "$candidate" != "None" && -n "$candidate" ]]; then
            SUBNET_ID="$candidate"
            AZ="$az"
            break
        fi
    done

    # Terminate execution if no valid subnet was found.
    [[ -n "$SUBNET_ID" ]] ||
        die "No default subnet was found in an AZ offering $INSTANCE_TYPE."

    # Print the resolved VPC identifier.
    echo "VPC         : $VPC_ID"
    # Print the resolved Subnet identifier.
    echo "Subnet      : $SUBNET_ID"
    # Print the resolved Availability Zone.
    echo "AZ          : $AZ"

    # Query AWS Systems Manager Parameter Store to resolve the latest Deep Learning AMI ID.
    AMI_ID="$(
        aws ssm get-parameter \
            --region "$REGION" \
            --name "$DLAMI_PARAMETER" \
            --query 'Parameter.Value' \
            --output text
    )"
    # Ensure a valid AMI ID was successfully resolved.
    [[ "$AMI_ID" != "None" && -n "$AMI_ID" ]] ||
        die "Could not resolve the current AWS Deep Learning AMI."

    # Print the resolved Deep Learning AMI ID.
    echo "DLAMI       : $AMI_ID"

    # Generate a unique security group name.
    SG_NAME="open-csusm-ssh-${ACCOUNT}-${RANDOM}"

    # Create a dedicated security group for SSH access.
    SG_ID="$(
        aws ec2 create-security-group \
            --region "$REGION" \
            --group-name "$SG_NAME" \
            --description "open CSUSM SSH-only security group" \
            --vpc-id "$VPC_ID" \
            --query 'GroupId' \
            --output text
    )"

    # Apply descriptive resource tags to the newly created security group.
    aws ec2 create-tags \
        --region "$REGION" \
        --resources "$SG_ID" \
        --tags \
            Key=Name,Value="$SG_NAME" \
            Key=Project,Value=open-CSUSM \
            Key=Owner,Value="$OWNER"

    # Authorize inbound SSH traffic exclusively on port 22 from the user's current public IP.
    aws ec2 authorize-security-group-ingress \
        --region "$REGION" \
        --group-id "$SG_ID" \
        --ip-permissions \
            "IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=${PUBLIC_IP}/32,Description='SSH from assignment laptop'}]"

    # Define user-data script to execute on instance boot.
    USER_DATA=$(cat <<'EOF'
#!/bin/bash
echo "open CSUSM boot complete" > /var/log/open-csusm-boot.txt
EOF
)

    # Launch the EC2 GPU instance with specified parameters and user data.
    INSTANCE_ID="$(
        aws ec2 run-instances \
            --region "$REGION" \
            --image-id "$AMI_ID" \
            --instance-type "$INSTANCE_TYPE" \
            --key-name "$KEY_NAME" \
            --subnet-id "$SUBNET_ID" \
            --security-group-ids "$SG_ID" \
            --associate-public-ip-address \
            --user-data "$USER_DATA" \
            --tag-specifications \
                "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=open-CSUSM},{Key=Owner,Value=${OWNER}}]" \
            --query 'Instances[0].InstanceId' \
            --output text
    )"

    # Export active deployment variables into the shell environment.
    export INSTANCE_ID SG_ID KEY_NAME KEY_PATH PUBLIC_IP VPC_ID SUBNET_ID AZ AMI_ID

    echo
    echo "Instance launched: $INSTANCE_ID"
    echo "Waiting for running state..."
    # Block execution until the EC2 instance reaches the running state.
    aws ec2 wait instance-running --region "$REGION" --instance-ids "$INSTANCE_ID"

    # Query instance metadata to retrieve its assigned public DNS hostname.
    DNS_NAME="$(
        aws ec2 describe-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            --query 'Reservations[0].Instances[0].PublicDnsName' \
            --output text
    )"

    PUBLIC_DNS="$DNS_NAME"
    SSH_USER="ec2-user"

    # Write deployment state variables to the local state file for subsequent stages.
    cat > "$STATE_FILE" <<EOF
REGION=$(printf '%q' "$REGION")
INSTANCE_TYPE=$(printf '%q' "$INSTANCE_TYPE")
MODEL=$(printf '%q' "$MODEL")
API_PORT=$(printf '%q' "$API_PORT")
INSTANCE_ID=$(printf '%q' "$INSTANCE_ID")
SG_ID=$(printf '%q' "$SG_ID")
VPC_ID=$(printf '%q' "$VPC_ID")
SUBNET_ID=$(printf '%q' "$SUBNET_ID")
AZ=$(printf '%q' "$AZ")
AMI_ID=$(printf '%q' "$AMI_ID")
KEY_NAME=$(printf '%q' "$KEY_NAME")
KEY_PATH=$(printf '%q' "$KEY_PATH")
PUBLIC_IP=$(printf '%q' "$PUBLIC_IP")
DNS_NAME=$(printf '%q' "$DNS_NAME")
PUBLIC_DNS=$(printf '%q' "$PUBLIC_DNS")
SSH_USER=$(printf '%q' "$SSH_USER")
EOF
    # Secure the state file permissions so only the owner can read or write it.
    chmod 600 "$STATE_FILE"

    # Print summary information and the exact SSH connection command.
    echo
    echo "============================================================"
    echo "SSH COMMAND"
    echo "============================================================"
    echo "ssh -i \"$KEY_PATH\" \"$SSH_USER@$DNS_NAME\""
    echo
    echo "Security Group: $SG_ID"
    echo "INBOUND: TCP/22 from $PUBLIC_IP/32 ONLY"
    echo "INBOUND: TCP/8000 = NONE"
    echo
    echo "The AWS meter starts now that we are running an EC2 instance."
    echo "Continue to stage 3."
}

# ------------------------------ Stage 3 -------------------------------------
stage3() {
    # Verify local prerequisites before executing SSH operations.
    check_local_prereqs
    # Load deployment state variables from the local state file.
    load_state

    # Print a formatted header banner for stage 3.
    echo "============================================================"
    echo "STAGE 3 - SSH in and install vLLM"
    echo "============================================================"
    echo

    # Poll the remote instance via SSH until port 22 responds.
    wait_for_ssh

    # Connect to the remote instance over SSH to configure the GPU environment and install vLLM.
    ssh -tt -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@$DNS_NAME" 'bash -s' <<'REMOTE'
set -euo pipefail

#GPU hardware verification.
echo "=== GPU CHECK ==="
# Query the NVIDIA system management interface to verify GPU hardware detection.
nvidia-smi

#Python version check.
echo
echo "=== Python check ==="
# Print the installed Python version on the remote instance.
python3 --version

#Package manager installation.
echo
echo "=== Installing uv if needed ==="
# Check if the astral uv package manager is installed, and download it if missing.
if ! command -v uv >/dev/null 2>&1; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi
# Add the local user binary path to the shell execution PATH variable.
export PATH="$HOME/.local/bin:$PATH"

#Virtual environment setup.
echo
echo "=== Creating isolated vLLM environment ==="
# Remove any pre-existing virtual environment directory to ensure a clean slate.
rm -rf "$HOME/opencsusm-venv"
# Create a fresh isolated Python 3.12 virtual environment using uv.
uv venv --python 3.12 --seed "$HOME/opencsusm-venv"
# Activate the virtual environment in the remote shell session.
source "$HOME/opencsusm-venv/bin/activate"

#vLLM package installation.
echo
echo "=== Installing vLLM ==="
# Install the vLLM inference engine and PyTorch backend inside the virtual environment.
uv pip install --upgrade vllm --torch-backend=auto

#vLLM software verification.
echo
echo "=== vLLM verification ==="
# Import vLLM via Python to verify successful software installation and print its version.
python -c 'import vllm; print("vLLM version:", vllm.__version__)'

#CUDA GPU visibility check.
echo
echo "=== GPU visible to PyTorch/vLLM ==="
# Verify that PyTorch successfully detects the underlying NVIDIA CUDA GPU device.
python -c 'import torch; print("CUDA available:", torch.cuda.is_available()); print("GPU:", torch.cuda.get_device_name(0) if torch.cuda.is_available() else "NONE")'

#stage 3 remote execution is complete.
echo
echo "STAGE 3 COMPLETE"
REMOTE
}

# ------------------------------ Stage 4 -------------------------------------
stage4() {
    # Verify local prerequisites before initiating server launch.
    check_local_prereqs
    # Load deployment state variables from configuration.
    load_state

    # Print a formatted header banner for stage 4.
    echo "============================================================"
    echo "STAGE 4 - serve Qwen with vLLM on localhost:8000"
    echo "============================================================"
    echo

    # Ensure the remote instance is reachable via SSH.
    wait_for_ssh

    # Connect via SSH to start the vLLM model server in the background using nohup.
    ssh -tt -i "$KEY_PATH" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        "$SSH_USER@$DNS_NAME" 'bash -s' <<REMOTE
set -euo pipefail

# Activate the isolated Python virtual environment containing vLLM.
source "\$HOME/opencsusm-venv/bin/activate"

# Terminate any previously running vLLM server processes to prevent port conflicts.
pkill -f "vllm serve" 2>/dev/null || true
# Remove old log files to capture a clean startup trace.
rm -f "\$HOME/vllm.log"

# Launch the vLLM server process in the background redirecting output to a log file.
nohup vllm serve "$MODEL" \
    --host 127.0.0.1 \
    --port $API_PORT \
    --dtype bfloat16 \
    --gpu-memory-utilization 0.65 \
    --max-model-len 2048 \
    --max-num-seqs 1 \
    --enforce-eager \
    > "\$HOME/vllm.log" 2>&1 &

# Process ID of the background vLLM server.
echo "vLLM PID: \$!"
# Status message indicating startup polling is underway.
echo "Waiting for startup complete..."

# Loop and poll the server log and API health endpoint until model initialization completes.
for i in \$(seq 1 180); do
    # Check the log file to confirm the application startup sequence has finished.
    if grep -q "Application startup complete" "\$HOME/vllm.log" 2>/dev/null; then
        echo
        echo "startup complete"
        break
    fi

    # Query the local OpenAPI models endpoint to verify HTTP server responsiveness.
    if curl -fsS http://127.0.0.1:$API_PORT/v1/models >/dev/null 2>&1; then
        echo
        echo "startup complete"
        break
    fi

    # Check if the vLLM background process exited unexpectedly due to an error.
    if ! kill -0 "\$!" 2>/dev/null; then
        echo
        echo "vLLM exited unexpectedly. Last log output:"
        tail -n 120 "\$HOME/vllm.log"
        exit 1
    fi

    # Pause execution briefly before the next poll iteration.
    sleep 5
done

# Terminate and output log output if the model server failed to become ready in time.
if ! curl -fsS http://127.0.0.1:$API_PORT/v1/models >/dev/null 2>&1; then
    echo "ERROR: vLLM did not become ready."
    tail -n 160 "\$HOME/vllm.log"
    exit 1
fi

# Model server is ready and serving requests.
echo
echo "Model server is READY."
echo "Instance localhost:$API_PORT is serving:"
# Output the list of served models to confirm successful API response.
curl -sS http://127.0.0.1:$API_PORT/v1/models
REMOTE
}

# ------------------------------ Stage 5 -------------------------------------
stage5() {
    # Verify local prerequisites before outputting tunnel instructions.
    check_local_prereqs
    # Load deployment state variables.
    load_state

    # Print a formatted header banner for stage 5.
    echo "============================================================"
    echo "STAGE 5 - SSH tunnel"
    echo "============================================================"
    echo
    echo "OPEN A SECOND TERMINAL."
    echo "Run the following command there and LEAVE IT RUNNING:"
    echo
    # Output the exact SSH local port forwarding command.
    echo "ssh -i \"$KEY_PATH\" -N -L $API_PORT:localhost:$API_PORT $SSH_USER@$DNS_NAME"
    echo
    echo "Then return to the FIRST terminal."
    # Explain how the port forwarding tunnel bridges local and remote ports.
    echo "The tunnel makes localhost:$API_PORT on your laptop point to"
    echo "localhost:$API_PORT on the EC2 instance through SSH port 22."
    echo
    # Reiterate that port 8000 has no inbound security group rules.
    echo "There is NO inbound Security Group rule for port $API_PORT."
}

# ------------------------------ Stage 6 -------------------------------------
stage6() {
    # Load deployment state variables.
    load_state

    # Print a formatted header banner for stage 6.
    echo "============================================================"
    echo "STAGE 6 - exact instructor test"
    echo "============================================================"
    echo
    echo "Run this command in the FIRST terminal while the Stage 5 tunnel"
    echo "is still running in the SECOND terminal."
    echo
    echo
    # Output the exact instructor test curl command for execution.
    cat <<'CURL'
curl -sS localhost:8000/v1/chat/completions \
  -H 'Content-Type: application/json' \
  -d '{"model": "Qwen/Qwen2.5-0.5B-Instruct", "messages": [{"role": "user", "content": "I am John"}], "max_tokens": 20, "temperature": 0}'
CURL
    echo
    echo
}

# ------------------------------ Stage 7 -------------------------------------
stage7() {
    # Verify local prerequisites prior to executing compute teardown.
    check_local_prereqs
    # Load deployment state variables to retrieve instance and security group IDs.
    load_state

    # Print a formatted header banner for stage 7.
    echo "============================================================"
    echo "STAGE 7 - STOP compute"
    echo "============================================================"
    echo

    # Send an API stop command to halt the EC2 compute instance and stop hourly billing.
    aws ec2 stop-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        >/dev/null

    # Block execution until the EC2 instance state fully transitions to stopped.
    aws ec2 wait instance-stopped \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        >/dev/null

    # Query the security group rules to verify that port 8000 remains closed.
    bad_8000="$(
        aws ec2 describe-security-groups \
            --region "$REGION" \
            --group-ids "$SG_ID" \
            --query 'SecurityGroups[0].IpPermissions[?FromPort==`8000` || ToPort==`8000`]' \
            --output json
    )"

    # Terminate execution with an error if port 8000 is incorrectly exposed.
    [[ "$bad_8000" == "[]" ]] || die "SECURITY FAILURE: port 8000 is exposed."

    # Print confirmation that compute is stopped and security rules remain intact.
    echo "STOPPED: $INSTANCE_ID"
    echo "TCP/8000 remains NOT exposed."
    echo "Continue immediately to stage 8 to delete the resources."
}

# ------------------------------ Stage 8 -------------------------------------
stage8() {
    # Load deployment state silently to obtain instance and security group identifiers.
    load_state >/dev/null

    # Query the current operational state of the EC2 instance to check if it is already terminated.
    if ! aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$INSTANCE_ID" \
        --query 'Reservations[0].Instances[0].State.Name' \
        --output text >/tmp/opencsusm_state.$$ 2>/tmp/opencsusm_err.$$; then
        cat /tmp/opencsusm_err.$$ >&2
        rm -f /tmp/opencsusm_state.$$ /tmp/opencsusm_err.$$ 
        exit 1
    fi

    # Read the instance state from the temporary file.
    state="$(cat /tmp/opencsusm_state.$$)"
    # Remove temporary state and error files.
    rm -f /tmp/opencsusm_state.$$ /tmp/opencsusm_err.$$

    if [[ "$state" == "terminated" ]]; then
        : 
    else
        # Issue an API command to permanently terminate and delete the EC2 instance.
        aws ec2 terminate-instances \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            >/dev/null
        # Block execution until the EC2 instance is completely terminated and removed.
        aws ec2 wait instance-terminated \
            --region "$REGION" \
            --instance-ids "$INSTANCE_ID" \
            >/dev/null
    fi

    # Check if the dedicated SSH security group still exists in the account.
    if aws ec2 describe-security-groups \
        --region "$REGION" \
        --group-ids "$SG_ID" \
        >/dev/null 2>&1; then
        # Delete the temporary security group to clean up all networking resources.
        aws ec2 delete-security-group \
            --region "$REGION" \
            --group-id "$SG_ID" \
            >/dev/null
    fi

    # Verify that the security group was successfully deleted.
    if aws ec2 describe-security-groups \
        --region "$REGION" \
        --group-ids "$SG_ID" \
        >/dev/null 2>&1; then
        echo "ERROR: Security Group $SG_ID still exists." >&2
        exit 1
    fi

    # Delete the local deployment state file to remove sensitive metadata.
    rm -f "$STATE_FILE"
    # Remove the local state directory if it is empty.
    rmdir "$STATE_DIR" 2>/dev/null || true
}

# ----------------------------- dispatcher -----------------------------------
# Print script usage instructions and available command arguments to standard error.
usage() {
    cat >&2 <<EOF
Usage:
  bash Garcia_Brian_CS446_Midterm.sh 1
  bash Garcia_Brian_CS446_Midterm.sh 2
  bash Garcia_Brian_CS446_Midterm.sh 3
  bash Garcia_Brian_CS446_Midterm.sh 4
  bash Garcia_Brian_CS446_Midterm.sh 5
  bash Garcia_Brian_CS446_Midterm.sh 6
  bash Garcia_Brian_CS446_Midterm.sh 7
  bash Garcia_Brian_CS446_Midterm.sh 8

Environment overrides:
  REGION=us-east-1
  KEY_NAME=your-ec2-key-name
  KEY_PATH=\$HOME/.ssh/your-key.pem
  OWNER=csusm
EOF
}

# Route script execution based on the positional stage argument provided.
case "${1:-}" in
    1) stage1 ;;
    2) stage2 ;;
    3) stage3 ;;
    4) stage4 ;;
    5) stage5 ;;
    6) stage6 ;;
    7) stage7 ;;
    8) stage8 ;;
    *) usage; exit 2 ;;
esac