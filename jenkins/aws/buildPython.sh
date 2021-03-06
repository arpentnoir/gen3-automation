#!/bin/bash

if [[ -n "${AUTOMATION_DEBUG}" ]]; then set ${AUTOMATION_DEBUG}; fi
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM

# Make sure we are in the build source directory
cd ${AUTOMATION_BUILD_SRC_DIR}

# Is this really a python based project
if [[ ! -f requirements.txt ]]; then
   echo -e "\nNo requirements.txt - is this really a python base repo?" >&2
   RESULT=1 && exit
fi

# Set up the virtual build environment - keep out of source tree
PYTHON_VERSION="${AUTOMATION_PYTHON_VERSION:+ -p } ${AUTOMATION_PYTHON_VERSION}"
virtualenv ${PYTHON_VERSION} ${AUTOMATION_BUILD_DIR}/.venv
RESULT=$?
if [ ${RESULT} -ne 0 ]; then
   echo -e "\nCreation of virtual build environment failed" >&2
   exit
fi
. ${AUTOMATION_BUILD_DIR}/.venv/bin/activate

# Process requirements files
shopt -s nullglob
REQUIREMENTS_FILES=( requirements*.txt )
for REQUIREMENTS_FILE in "${REQUIREMENTS_FILES[@]}"; do
    pip install -r ${REQUIREMENTS_FILE} --upgrade
    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
       echo -e "\nInstallation of requirements failed" >&2
       exit
    fi
done

if [[ -f package.json ]]; then
    npm install --unsafe-perm
    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
       echo -e "\nnpm install failed" >&2
       exit
    fi
fi

# Run bower as part of the build if required
if [[ -f bower.json ]]; then
    bower install --allow-root
    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
       echo -e "\nbower install failed" >&2
       exit
    fi
fi

# Run unit tests - there should always be a task even if it does nothing
if [[ -f manage.py ]]; then
    python manage.py test
fi

# Patch the virtual env if packages have not been installed into site-packages dir
# This is a defect in zappa 0.42, in that it doesn't allow for platforms that install
# packages into dist-packages. Remove this patch once zappa is fixed
if [[ -n ${VIRTUAL_ENV} ]]; then
    SITE_PACKAGES_DIR=$(find ${VIRTUAL_ENV}/lib -name site-packages)
    if [[ -n ${SITE_PACKAGES_DIR} ]]; then
      if [[ $(find ${SITE_PACKAGES_DIR} -type d | wc -l) < 2 ]]; then
        cp -rp ${SITE_PACKAGES_DIR}/../dist-packages/*  ${SITE_PACKAGES_DIR}
      fi
    fi
fi

# Package for lambda if required
for ZAPPA_DIR in "${AUTOMATION_BUILD_DEVOPS_DIR}/lambda" "./"; do
    if [[ -f "${ZAPPA_DIR}/zappa_settings.json" ]]; then
        BUILD=$(zappa -s ${ZAPPA_DIR}/zappa_settings.json package default | tail -1 | cut -d' ' -f3)
        if [[ -f ${BUILD} ]]; then
            mkdir -p "${AUTOMATION_BUILD_DIR}/dist"
            mv ${BUILD} "${AUTOMATION_BUILD_DIR}/dist/lambda.zip"
        fi
    fi
done

# Clean up
if [[ -f package.json ]]; then
    npm prune --production
    RESULT=$?
    if [ ${RESULT} -ne 0 ]; then
       echo -e "\nnpm prune failed" >&2
       exit
    fi
fi

# All good
RESULT=0
