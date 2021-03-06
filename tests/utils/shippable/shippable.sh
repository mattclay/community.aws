#!/usr/bin/env bash

set -o pipefail -eux

declare -a args
IFS='/:' read -ra args <<< "$1"

script="${args[0]}"

test="$1"

docker images ansible/ansible
docker images quay.io/ansible/*
docker ps

for container in $(docker ps --format '{{.Image}} {{.ID}}' | grep -v '^drydock/' | sed 's/^.* //'); do
    docker rm -f "${container}" || true  # ignore errors
done

docker ps

if [ -d /home/shippable/cache/ ]; then
    ls -la /home/shippable/cache/
fi

command -v python
python -V

command -v pip
pip --version
pip list --disable-pip-version-check

export PATH="${PWD}/bin:${PATH}"
export PYTHONIOENCODING='utf-8'

if [ "${JOB_TRIGGERED_BY_NAME:-}" == "nightly-trigger" ]; then
#    COVERAGE=yes
    COMPLETE=yes
fi

#if [ -n "${COVERAGE:-}" ]; then
#    # on-demand coverage reporting triggered by setting the COVERAGE environment variable to a non-empty value
#    export COVERAGE="--coverage"
#elif [[ "${COMMIT_MESSAGE}" =~ ci_coverage ]]; then
#    # on-demand coverage reporting triggered by having 'ci_coverage' in the latest commit message
#    export COVERAGE="--coverage"
#else
#    # on-demand coverage reporting disabled (default behavior, always-on coverage reporting remains enabled)
#    export COVERAGE="--coverage-check"
#fi

if [ -n "${COMPLETE:-}" ]; then
    # disable change detection triggered by setting the COMPLETE environment variable to a non-empty value
    export CHANGED=""
elif [[ "${COMMIT_MESSAGE}" =~ ci_complete ]]; then
    # disable change detection triggered by having 'ci_complete' in the latest commit message
    export CHANGED=""
else
    # enable change detection (default behavior)
    #export CHANGED="--changed"
    export CHANGED=""  # disable changed detection https://github.com/ansible/ansible/issues/67869
fi

if [ "${IS_PULL_REQUEST:-}" == "true" ]; then
    # run unstable tests which are targeted by focused changes on PRs
    export UNSTABLE="--allow-unstable-changed"
else
    # do not run unstable tests outside PRs
    export UNSTABLE=""
fi

virtualenv --python /usr/bin/python3.7 ~/ansible-venv
set +ux
. ~/ansible-venv/bin/activate
set -ux

pip install git+https://github.com/ansible-collection-migration/ansible-base

#ansible-galaxy collection install community.general
mkdir -p "${HOME}/.ansible/ansible_collections/community"
mkdir -p "${HOME}/.ansible/ansible_collections/google"
mkdir -p "${HOME}/.ansible/ansible_collections/openstack"
cwd=$(pwd)
cd "${HOME}/.ansible/ansible_collections/"
git clone https://github.com/ansible-collections/community.general community/general
git clone https://github.com/ansible-collection-migration/ansible.amazon ansible/amazon
# community.general requires a lot of things we need to manual pull in
# once community.general is published this will be handled by galaxy cli
git clone https://github.com/ansible-collection-migration/google.cloud google/cloud
git clone https://github.com/ansible-collection-migration/openstack.cloud openstack/cloud
git clone https://github.com/ansible-collection-migration/ansible.netcommon ansible/netcommon
#ansible-galaxy collection install ansible.netcommon
cd "${cwd}"

export ANSIBLE_COLLECTIONS_PATHS="${HOME}/.ansible/"
TEST_DIR="${HOME}/.ansible/ansible_collections/community/amazon/"
mkdir -p "${TEST_DIR}"
cp -aT "${SHIPPABLE_BUILD_DIR}" "${TEST_DIR}"
cd "${TEST_DIR}"

function cleanup
{
    if [ -d tests/output/coverage/ ]; then
        if find tests/output/coverage/ -mindepth 1 -name '.*' -prune -o -print -quit | grep -q .; then
            # for complete on-demand coverage generate a report for all files with no coverage on the "other" job so we only have one copy
            if [ "${COVERAGE}" == "--coverage" ] && [ "${CHANGED}" == "" ] && [ "${test}" == "sanity/1" ]; then
                stub="--stub"
            else
                stub=""
            fi

            # shellcheck disable=SC2086
            ansible-test coverage xml --color -v --requirements --group-by command --group-by version ${stub:+"$stub"}
            cp -a tests/output/reports/coverage=*.xml shippable/codecoverage/
        fi
    fi

    if [ -d  tests/output/junit/ ]; then
      cp -aT tests/output/junit/ shippable/testresults/
    fi

    if [ -d tests/output/data/ ]; then
      cp -a tests/output/data/ shippable/testresults/
    fi

    if [ -d  tests/output/bot/ ]; then
      cp -aT tests/output/bot/ shippable/testresults/
    fi
}

trap cleanup EXIT

if [[ "${COVERAGE:-}" == "--coverage" ]]; then
    timeout=60
else
    timeout=45
fi

ansible-test env --dump --show --timeout "${timeout}" --color -v

"tests/utils/shippable/check_matrix.py"
"tests/utils/shippable/${script}.sh" "${test}"
