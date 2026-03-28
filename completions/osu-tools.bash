# Bash completion for OSU Tools (OpenStack User Tools)
# Source this file or install to /etc/bash_completion.d/
#
# Requires bash-completion (provides _get_comp_words_by_ref).
# Falls back to manual COMP_WORDS parsing if unavailable.

# Portable helper: set cur/prev from COMP_WORDS
_osu_comp_init() {
    if declare -F _get_comp_words_by_ref &>/dev/null; then
        _osu_comp_init
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
    fi
}

# --- osu-import-cloud-images.sh ----------------------------------------------

_osu_import_cloud_images() {
    local cur prev
    _osu_comp_init

    case "$prev" in
        -d|--distro)
            COMPREPLY=( $(compgen -W "debian ubuntu rocky opensuse oracle" -- "$cur") )
            return
            ;;
        -f|--format)
            COMPREPLY=( $(compgen -W "raw qcow2" -- "$cur") )
            return
            ;;
        --visibility)
            COMPREPLY=( $(compgen -W "public private" -- "$cur") )
            return
            ;;
        --arch)
            COMPREPLY=( $(compgen -W "x86_64" -- "$cur") )
            return
            ;;
        --os-license)
            COMPREPLY=( $(compgen -W "opensource rhel" -- "$cur") )
            return
            ;;
    esac

    if [[ "$cur" == --* ]]; then
        COMPREPLY=( $(compgen -W "
            --help --version --interactive --batch --list
            --distro --format --visibility --os-license
            --force --no-customize --arch --dry-run
        " -- "$cur") )
    elif [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "
            -h -v -i -b -l -d -f -n
            --help --version --interactive --batch --list
            --distro --format --visibility --os-license
            --force --no-customize --arch --dry-run
        " -- "$cur") )
    fi
}

complete -F _osu_import_cloud_images osu-import-cloud-images.sh
complete -F _osu_import_cloud_images osu-import-cloud-images

# --- osu-memory-usage-report.sh -----------------------------------------------

_osu_memory_usage_report() {
    local cur prev
    _osu_comp_init

    if [[ "$cur" == --* ]]; then
        COMPREPLY=( $(compgen -W "--help --version" -- "$cur") )
    elif [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-h -v --help --version" -- "$cur") )
    else
        # Complete with OpenStack domain names if openstack CLI is available
        if command -v openstack &>/dev/null; then
            local domains
            domains=$(openstack domain list -f value -c Name 2>/dev/null)
            if [[ -n "$domains" ]]; then
                COMPREPLY=( $(compgen -W "$domains" -- "$cur") )
            fi
        fi
    fi
}

complete -F _osu_memory_usage_report osu-memory-usage-report.sh
complete -F _osu_memory_usage_report osu-memory-usage-report

# --- osu-retype-vdisk.sh -----------------------------------------------------

_osu_retype_vdisk_volumes() {
    if command -v openstack &>/dev/null; then
        openstack volume list -f value -c ID 2>/dev/null
    fi
}

_osu_retype_vdisk_volume_types() {
    if command -v openstack &>/dev/null; then
        openstack volume type list -f value -c Name 2>/dev/null
    fi
}

_osu_retype_vdisk_servers() {
    if command -v openstack &>/dev/null; then
        openstack server list -f value -c Name 2>/dev/null
    fi
}

_osu_retype_vdisk_containers() {
    if command -v openstack &>/dev/null; then
        openstack container list -f value -c Name 2>/dev/null
    fi
}

_osu_retype_vdisk() {
    local cur prev
    _osu_comp_init

    case "$prev" in
        -r|--retype)
            local volumes
            volumes=$(_osu_retype_vdisk_volumes)
            COMPREPLY=( $(compgen -W "$volumes" -- "$cur") )
            return
            ;;
        -T|--type)
            local types
            types=$(_osu_retype_vdisk_volume_types)
            COMPREPLY=( $(compgen -W "$types" -- "$cur") )
            return
            ;;
        -s|--server)
            local servers
            servers=$(_osu_retype_vdisk_servers)
            COMPREPLY=( $(compgen -W "$servers" -- "$cur") )
            return
            ;;
        -f|--format)
            COMPREPLY=( $(compgen -W "table csv json" -- "$cur") )
            return
            ;;
        --handle-snapshots)
            COMPREPLY=( $(compgen -W "delete backup-delete" -- "$cur") )
            return
            ;;
        --backup-container)
            local containers
            containers=$(_osu_retype_vdisk_containers)
            COMPREPLY=( $(compgen -W "$containers" -- "$cur") )
            return
            ;;
        --handle-vm-state)
            COMPREPLY=( $(compgen -W "start-stop detach-reattach" -- "$cur") )
            return
            ;;
        --interval|--timeout)
            # Numeric arguments — no completion
            return
            ;;
        -m|--monitor)
            local volumes
            volumes=$(_osu_retype_vdisk_volumes)
            COMPREPLY=( $(compgen -W "$volumes" -- "$cur") )
            return
            ;;
    esac

    if [[ "$cur" == --* ]]; then
        COMPREPLY=( $(compgen -W "
            --help --version --interactive --list --types
            --retype --type --monitor --server
            --format --yes --dry-run --no-monitor
            --interval --timeout
            --handle-snapshots --backup-container
            --handle-vm-state
        " -- "$cur") )
    elif [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "
            -h -v -i -l -t -r -T -m -s -f -y -n
            --help --version --interactive --list --types
            --retype --type --monitor --server
            --format --yes --dry-run --no-monitor
            --interval --timeout
            --handle-snapshots --backup-container
            --handle-vm-state
        " -- "$cur") )
    else
        # Positional arg after -m/--monitor: complete with volume IDs
        local i
        for (( i=1; i < ${#COMP_WORDS[@]}-1; i++ )); do
            if [[ "${COMP_WORDS[i]}" == "-m" || "${COMP_WORDS[i]}" == "--monitor" ]]; then
                local volumes
                volumes=$(_osu_retype_vdisk_volumes)
                COMPREPLY=( $(compgen -W "$volumes" -- "$cur") )
                return
            fi
        done
    fi
}

complete -F _osu_retype_vdisk osu-retype-vdisk.sh
complete -F _osu_retype_vdisk osu-retype-vdisk

# --- osu-resource-efficiency-report.sh ----------------------------------------

_osu_resource_efficiency_report() {
    local cur prev
    _osu_comp_init

    case "$prev" in
        -p|--project)
            if command -v openstack &>/dev/null; then
                local projects
                projects=$(openstack project list -f value -c Name 2>/dev/null)
                COMPREPLY=( $(compgen -W "$projects" -- "$cur") )
            fi
            return
            ;;
        -f|--format)
            COMPREPLY=( $(compgen -W "table csv json" -- "$cur") )
            return
            ;;
    esac

    if [[ "$cur" == --* ]]; then
        COMPREPLY=( $(compgen -W "
            --help --version --project --format
            --all-projects --no-diagnostics --dry-run
        " -- "$cur") )
    elif [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "
            -h -v -p -f -a -n
            --help --version --project --format
            --all-projects --no-diagnostics --dry-run
        " -- "$cur") )
    else
        # Positional: domain names
        if command -v openstack &>/dev/null; then
            local domains
            domains=$(openstack domain list -f value -c Name 2>/dev/null)
            if [[ -n "$domains" ]]; then
                COMPREPLY=( $(compgen -W "$domains" -- "$cur") )
            fi
        fi
    fi
}

complete -F _osu_resource_efficiency_report osu-resource-efficiency-report.sh
complete -F _osu_resource_efficiency_report osu-resource-efficiency-report
