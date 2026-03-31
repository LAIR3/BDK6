#!/bin/bash

# Define minimum versions required to run the Kurtosis CDK packages.
KURTOSIS_VERSION_SUPPORTED=1.0
DOCKER_VERSION_SUPPORTED=24.7
PODMAN_VERSION_SUPPORTED=4.0
YQ_VERSION_SUPPORTED=3.2

## Helper functions.
ensure_required_tool_is_installed() {
    local tool="$1"
    local install_docs="$2"
    if ! command -v "$tool" &>/dev/null; then
        echo "❌ $tool is not installed. Please install $tool to proceed: $install_docs"
        exit 1
    fi
}

ensure_optional_tool_is_installed() {
    local tool="$1"
    local install_docs="$2"
    if ! command -v "$tool" &>/dev/null; then
        echo "🟡 Optional $tool is not installed. You can install $tool at: $install_docs"
        return 1
    fi
}

## Check tool versions.
check_kurtosis_version() {
    kurtosis_install_docs="https://docs.kurtosis.com/install/"
    ensure_required_tool_is_installed "kurtosis" "$kurtosis_install_docs"

    major_kurtosis_version_supported="$(echo "$KURTOSIS_VERSION_SUPPORTED" | cut -d '.' -f 1)"
    minor_kurtosis_version_supported="$(echo "$KURTOSIS_VERSION_SUPPORTED" | cut -d '.' -f 2)"

    kurtosis_version="$(kurtosis version | head -n 1 | cut -d ' ' -f 5)"
    major_kurtosis_version="$(echo "$kurtosis_version" | cut -d '.' -f 1)"
    minor_kurtosis_version="$(echo "$kurtosis_version" | cut -d '.' -f 2)"

    if [ "$major_kurtosis_version" -gt "$major_kurtosis_version_supported" ] || \
        { [ "$major_kurtosis_version" -eq "$major_kurtosis_version_supported" ] && [ "$minor_kurtosis_version" -ge "$minor_kurtosis_version_supported" ]; }; then
        echo "✅ kurtosis $kurtosis_version is installed, meets the requirement (>=$KURTOSIS_VERSION_SUPPORTED)."
    else
        echo "❌ kurtosis $kurtosis_version is installed, but version >=$KURTOSIS_VERSION_SUPPORTED is required."
        exit 1
    fi
}

check_container_runtime() {
    # Check for podman first (preferred), then docker
    if command -v podman &>/dev/null; then
        podman_version="$(podman --version | awk '{print $3}')"
        major_podman="$(echo "$podman_version" | cut -d '.' -f 1)"
        minor_podman="$(echo "$podman_version" | cut -d '.' -f 2)"

        major_podman_supported="$(echo "$PODMAN_VERSION_SUPPORTED" | cut -d '.' -f 1)"
        minor_podman_supported="$(echo "$PODMAN_VERSION_SUPPORTED" | cut -d '.' -f 2)"

        if [ "$major_podman" -gt "$major_podman_supported" ] || \
            { [ "$major_podman" -eq "$major_podman_supported" ] && [ "$minor_podman" -ge "$minor_podman_supported" ]; }; then
            echo "✅ podman $podman_version is installed, meets the requirement (>=$PODMAN_VERSION_SUPPORTED)."
        else
            echo "❌ podman $podman_version is installed, but version >=$PODMAN_VERSION_SUPPORTED is required."
            exit 1
        fi

        # Check docker compatibility layer
        if command -v docker &>/dev/null; then
            echo "✅ docker CLI compatibility is available (via podman-docker)."
        else
            echo "🟡 docker CLI alias not found. Install podman-docker for full compatibility."
        fi
        return 0
    fi

    if command -v docker &>/dev/null; then
        docker_install_docs="https://docs.docker.com/engine/install/"

        major_docker_version_supported="$(echo "$DOCKER_VERSION_SUPPORTED" | cut -d '.' -f 1)"
        minor_docker_version_supported="$(echo "$DOCKER_VERSION_SUPPORTED" | cut -d '.' -f 2)"

        docker_version="$(docker --version | awk '{print $3}' | cut -d ',' -f 1)"
        major_docker_version="$(echo "$docker_version" | cut -d '.' -f 1)"
        minor_docker_version="$(echo "$docker_version" | cut -d '.' -f 2)"

        if [ "$major_docker_version" -ge "$major_docker_version_supported" ] || \
            { [ "$major_docker_version" -eq "$major_docker_version_supported" ] && [ "$minor_docker_version" -ge "$minor_docker_version_supported" ]; }; then
            echo "✅ docker $docker_version is installed, meets the requirement (>=$DOCKER_VERSION_SUPPORTED)."
        else
            echo "❌ docker $docker_version is installed, but only version $DOCKER_VERSION_SUPPORTED is supported by the package."
            exit 1
        fi
        return 0
    fi

    echo "❌ No container runtime found. Install podman (preferred) or docker."
    echo "   Podman: apt install podman podman-docker"
    echo "   Docker: https://docs.docker.com/engine/install/"
    exit 1
}

check_jq_version() {
    jq_install_docs="https://jqlang.github.io/jq/download/"
    if ensure_optional_tool_is_installed "jq" "$jq_install_docs"; then
        jq_version="$(jq --version | cut -d '-' -f 2)"
        echo "✅ jq $jq_version is installed."
    fi
}

check_yq_version() {
    yq_install_docs="https://pypi.org/project/yq/"
    if ensure_optional_tool_is_installed "yq" "$yq_install_docs"; then
        yq_major_version_supported="$(echo "$YQ_VERSION_SUPPORTED" | cut -d '.' -f 1)"
        yq_minor_version_supported="$(echo "$YQ_VERSION_SUPPORTED" | cut -d '.' -f 2)"

        yq_version="$(yq --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
        major_yq_version="$(echo "$yq_version" | cut -d '.' -f 1)"
        minor_yq_version="$(echo "$yq_version" | cut -d '.' -f 2)"
        if [ "$major_yq_version" -gt "$yq_major_version_supported" ] || \
            { [ "$major_yq_version" -eq "$yq_major_version_supported" ] && [ "$minor_yq_version" -ge "$yq_minor_version_supported" ]; }; then
            echo "✅ yq $yq_version is installed, meets the requirement (>=$YQ_VERSION_SUPPORTED)."
        else
            echo "❌ yq $yq_version is installed, but only version $YQ_VERSION_SUPPORTED is supported by the package."
            exit 1
        fi
    fi
}

check_cast_version() {
    cast_install_docs="https://book.getfoundry.sh/getting-started/installation#using-foundryup"
    if ensure_optional_tool_is_installed "cast" "$cast_install_docs"; then
        cast_version="$(cast --version | cut -d ' ' -f 2)"
        echo "✅ cast $cast_version is installed."
    fi
}

check_polycli_version() {
    polycli_install_docs="https://github.com/maticnetwork/polygon-cli/releases"
    if ensure_optional_tool_is_installed "polycli" "$polycli_install_docs"; then
        polycli_version="$(polycli version | cut -d ' ' -f 4)"
        echo "✅ polycli $polycli_version is installed."
    fi
}

## Main function.
main() {
    echo "Checking that you have the necessary tools to deploy the Kurtosis CDK package..."
    check_kurtosis_version
    check_container_runtime

    echo; echo "You might as well need the following tools to interact with the environment..."
    check_jq_version
    check_yq_version
    check_cast_version
    check_polycli_version

    echo; echo "🎉 You are ready to go!"
}

main
