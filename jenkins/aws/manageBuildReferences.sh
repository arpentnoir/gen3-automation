#!/bin/bash

if [[ -n "${AUTOMATION_DEBUG}" ]]; then set ${AUTOMATION_DEBUG}; fi
trap 'exit ${RESULT:-1}' EXIT SIGHUP SIGINT SIGTERM

# Defaults
REFERENCE_OPERATION_ACCEPT="accept"
REFERENCE_OPERATION_LIST="list"
REFERENCE_OPERATION_LISTFULL="listfull"
REFERENCE_OPERATION_UPDATE="update"
REFERENCE_OPERATION_VERIFY="verify"
REFERENCE_OPERATION_DEFAULT="${REFERENCE_OPERATION_LIST}"

function usage() {
    cat <<EOF

Manage build references for one or more deployment units

Usage: $(basename $0)   -s DEPLOYMENT_UNIT_LIST -g SEGMENT_APPSETTINGS_DIR
                        -c CODE_COMMIT_LIST -t CODE_TAG_LIST -r CODE_REPO_LIST 
                        -p CODE_PROVIDER_LIST -i IMAGE_FORMATS_LIST
                        -a ACCEPTANCE_TAG -v VERIFICATION_TAG -f -l -u
where
(o) -a ACCEPTANCE_TAG (REFERENCE_OPERATION=${REFERENCE_OPERATION_ACCEPT}) to tag all builds as accepted
(o) -c CODE_COMMIT_LIST             is the commit for each deployment unit
(o) -f (REFERENCE_OPERATION=${REFERENCE_OPERATION_LISTFULL}) to detail full build info
(o) -g SEGMENT_APPSETTINGS_DIR      is the segment appsettings to be managed
    -h                              shows this text
(o) -i IMAGE_FORMATS_LIST           is the list of image formats for each deployment unit
(o) -l (REFERENCE_OPERATION=${REFERENCE_OPERATION_LIST}) to detail DEPLOYMENT_UNIT_LIST build info
(o) -p CODE_PROVIDER_LIST           is the repo provider for each deployment unit
(o) -r CODE_REPO_LIST               is the repo for each deployment unit
(m) -s DEPLOYMENT_UNIT_LIST         is the list of deployment units to process
(o) -t CODE_TAG_LIST                is the tag for each deployment unit                                          
(o) -u (REFERENCE_OPERATION=${REFERENCE_OPERATION_UPDATE}) to update build references
(o) -v VERIFICATION_TAG (REFERENCE_OPERATION=${REFERENCE_OPERATION_VERIFY}) to verify build references

(m) mandatory, (o) optional, (d) deprecated

DEFAULTS:

REFERENCE_OPERATION = ${REFERENCE_OPERATION_DEFAULT}

NOTES:

1. Appsettings directory must include segment directory
2. If there is no commit for a deployment unit, CODE_COMMIT_LIST must contain a "?"
3. If there is no repo for a deployment unit, CODE_REPO_LIST must contain a "?"
4. If there is no tag for a deployment unit, CODE_TAG_LIST must contain a "?"
5. Lists can be shorter than the DEPLOYMENT_UNIT_LIST. If shorter, they
   are padded with "?" to match the length of DEPLOYMENT_UNIT_LIST

EOF
    exit
}

# Update DETAIL_MESSAGE with build information
# $1 = deployment unit
# $2 = build commit (? = no commit)
# $3 = build tag (? = no tag)
# $4 = image formats (? = not provided)
function updateDetail() {
    local UD_DEPLOYMENT_UNIT="${1,,}"
    local UD_COMMIT="${2,,:-?}"
    local UD_TAG="${3:-?}"
    local UD_FORMATS="${4,,:-?}"

    if [[ ("${UD_COMMIT}" != "?") || ("${UD_TAG}" != "?") ]]; then
        DETAIL_MESSAGE="${DETAIL_MESSAGE}, ${UD_DEPLOYMENT_UNIT}="
        if [[ "${UD_FORMATS}" != "?" ]]; then
            DETAIL_MESSAGE="${DETAIL_MESSAGE}${UD_FORMATS}:"
        fi
        if [[ "${UD_TAG}" != "?" ]]; then
            # Format is tag then commit if provided
            DETAIL_MESSAGE="${DETAIL_MESSAGE}${UD_TAG}"
            if [[ "${UD_COMMIT}" != "?" ]]; then
                DETAIL_MESSAGE="${DETAIL_MESSAGE} (${UD_COMMIT:0:7})"
            fi
        else
            # Format is just the commit
            DETAIL_MESSAGE="${DETAIL_MESSAGE}${UD_COMMIT:0:7}"
        fi
    fi
}

# Extract parts of a build reference
# The legacy format uses a space separated, fixed position parts
# The current format uses JSON with parts as attributes
# $1 = build reference
function getBuildReferenceParts() {
    local GBRP_REFERENCE="${1}"
    local ATTRIBUTE=
    
    if [[ "${GBRP_REFERENCE}" =~ ^\{ ]]; then
        # Newer JSON based format
        for ATTRIBUTE in commit tag format; do 
            ATTRIBUTE_VALUE=$(jq -r ".${ATTRIBUTE} | select(.!=null)" <<< "${GBRP_REFERENCE}")
            if [[ -z "${ATTRIBUTE_VALUE}" ]]; then
                ATTRIBUTE_VALUE=$(jq -r ".${ATTRIBUTE^} | select(.!=null)" <<< "${GBRP_REFERENCE}")
            fi
            declare -g "BUILD_REFERENCE_${ATTRIBUTE^^}"="${ATTRIBUTE_VALUE:-?}"
        done
        for ATTRIBUTE in formats; do 
            ATTRIBUTE_VALUE=$(jq -r ".${ATTRIBUTE} | select(.!=null) | .[]" <<< "${GBRP_REFERENCE}" | tr -s "\r\n" "${IMAGE_FORMAT_SEPARATORS:0:1}")
            if [[ -z "${ATTRIBUTE_VALUE}" ]]; then
                ATTRIBUTE_VALUE=$(jq -r ".${ATTRIBUTE^} | select(.!=null) | .[]" <<< "${GBRP_REFERENCE}" | tr -s "\r\n" "${IMAGE_FORMAT_SEPARATORS:0:1}")
            fi
            declare -g "BUILD_REFERENCE_${ATTRIBUTE^^}"="${ATTRIBUTE_VALUE:-?}"
        done
        if [[ "${BUILD_REFERENCE_FORMATS}" == "?" ]]; then
            BUILD_REFERENCE_FORMATS="${BUILD_REFERENCE_FORMAT}"
        fi
    else
        BUILD_REFERENCE_ARRAY=(${GBRP_REFERENCE})
        BUILD_REFERENCE_COMMIT="${BUILD_REFERENCE_ARRAY[0]:-?}"
        BUILD_REFERENCE_TAG="${BUILD_REFERENCE_ARRAY[1]:-?}"
        BUILD_REFERENCE_FORMATS="?"
    fi
}

# Format a JSON based build reference
# $1 = build commit
# $2 = build tag (? = no tag)
# $3 = formats (default is docker)
function formatBuildReference() {
    local FBR_COMMIT="${1,,}"
    local FBR_TAG="${2:-?}"
    local FBR_FORMATS="${3,,:-?}"

    BUILD_REFERENCE="{\"Commit\": \"${FBR_COMMIT}\""
    if [[ "${FBR_TAG}" != "?" ]]; then 
        BUILD_REFERENCE="${BUILD_REFERENCE}, \"Tag\": \"${FBR_TAG}\""
    fi
    if [[ "${FBR_FORMATS}" == "?" ]]; then
        FBR_FORMATS="docker"
    fi
    IFS="${IMAGE_FORMAT_SEPARATORS}" read -ra FBR_FORMATS_ARRAY <<< "${FBR_FORMATS}"
    BUILD_REFERENCE="${BUILD_REFERENCE}, \"Formats\": [\"${FBR_FORMATS_ARRAY[0]}\""
    for ((FORMAT_INDEX=1; FORMAT_INDEX<${#FBR_FORMATS_ARRAY[@]}; FORMAT_INDEX++)); do
        BUILD_REFERENCE="${BUILD_REFERENCE},\"${FBR_FORMATS_ARRAY[$FORMAT_INDEX]}\""
    done
    BUILD_REFERENCE="${BUILD_REFERENCE} ]}"
}

# Define git provider attributes
# $1 = provider
# $2 = variable prefix
function defineGitProviderAttributes() {
    local DGPA_PROVIDER="${1^^}"
    local DGPA_PREFIX="${2^^}"

    # Attribute variable names
    for DGPA_ATTRIBUTE in "DNS" "API_DNS" "ORG" "CREDENTIALS_VAR"; do
        DGPA_PROVIDER_VAR="${DGPA_PROVIDER}_GIT_${DGPA_ATTRIBUTE}"
        declare -g ${DGPA_PREFIX}_${DGPA_ATTRIBUTE}="${!DGPA_PROVIDER_VAR}"
    done
}

# Parse options
while getopts ":a:c:fg:hi:lp:r:s:t:uv:z:" opt; do
    case $opt in
        a)
            REFERENCE_OPERATION="${REFERENCE_OPERATION_ACCEPT}"
            ACCEPTANCE_TAG="${OPTARG}"
            ;;
        c)
            CODE_COMMIT_LIST="${OPTARG}"
            ;;
        f)
            REFERENCE_OPERATION="${REFERENCE_OPERATION_LISTFULL}"
            ;;
        g)
            SEGMENT_APPSETTINGS_DIR="${OPTARG}"
            ;;
        h)
            usage
            ;;
        i)
            IMAGE_FORMATS_LIST="${OPTARG}"
            ;;
        l)
            REFERENCE_OPERATION="${REFERENCE_OPERATION_LIST}"
            ;;
        p)
            CODE_PROVIDER_LIST="${OPTARG}"
            ;;
        r)
            CODE_REPO_LIST="${OPTARG}"
            ;;
        s)
            DEPLOYMENT_UNIT_LIST="${OPTARG}"
            ;;
        t)
            CODE_TAG_LIST="${OPTARG}"
            ;;
        u)
            REFERENCE_OPERATION="${REFERENCE_OPERATION_UPDATE}"
            ;;
        v)
            REFERENCE_OPERATION="${REFERENCE_OPERATION_VERIFY}"
            VERIFICATION_TAG="${OPTARG}"            
            ;;
        \?)
            echo -e "\nInvalid option: -${OPTARG}" >&2
            exit
            ;;
        :)
            echo -e "\nOption -${OPTARG} requires an argument" >&2
            exit
            ;;
     esac
done

# Apply defaults
REFERENCE_OPERATION="${REFERENCE_OPERATION:-${REFERENCE_OPERATION_DEFAULT}}"

# Ensure mandatory arguments have been provided
case ${REFERENCE_OPERATION} in
    ${REFERENCE_OPERATION_ACCEPT})
        # Add the acceptance tag on provided deployment unit list
        # Normally this would be called after list full
        if [[ (-z "${DEPLOYMENT_UNIT_LIST}") ||
                (-z "${ACCEPTANCE_TAG}") ]]; then
            echo -e "\nInsufficient arguments" >&2
            exit
        fi
        ;;

    ${REFERENCE_OPERATION_LIST})
        # Format the build details based on provided deployment unit list
        if [[ (-z "${DEPLOYMENT_UNIT_LIST}") ]]; then
            echo -e "\nInsufficient arguments" >&2
            exit
        fi
        ;;

    ${REFERENCE_OPERATION_LISTFULL})
        # Populate DEPLOYMENT_UNIT_LIST based on current appsettings
        if [[ -z "${SEGMENT_APPSETTINGS_DIR}" ]]; then
            echo -e "\nInsufficient arguments" >&2
            exit
        fi
        ;;

    ${REFERENCE_OPERATION_UPDATE})
        # Update builds based on provided deployment unit list
        if [[ (-z "${DEPLOYMENT_UNIT_LIST}") ||
                (-z "${SEGMENT_APPSETTINGS_DIR}") ]]; then
            echo -e "\nInsufficient arguments" >&2
            exit
        fi
        ;;

    ${REFERENCE_OPERATION_VERIFY})
        # Verify builds based on provided deployment unit list
        if [[ (-z "${DEPLOYMENT_UNIT_LIST}") ||
                (-z "${VERIFICATION_TAG}") ]]; then
            echo -e "\nInsufficient arguments" >&2
            exit
        fi
        ;;

    *)
        echo -e "\nInvalid REFERENCE_OPERATION \"${REFERENCE_OPERATION}\"" >&2
        exit
        ;;
esac


# Access existing build info
DEPLOYMENT_UNIT_ARRAY=(${DEPLOYMENT_UNIT_LIST})
CODE_COMMIT_ARRAY=(${CODE_COMMIT_LIST})
CODE_TAG_ARRAY=(${CODE_TAG_LIST})
CODE_REPO_ARRAY=(${CODE_REPO_LIST})
CODE_PROVIDER_ARRAY=(${CODE_PROVIDER_LIST})
IMAGE_FORMATS_ARRAY=(${IMAGE_FORMATS_LIST})

if [[ -n "${SEGMENT_APPSETTINGS_DIR}" ]]; then
    # Most operations require access to the segment build settings
    mkdir -p ${SEGMENT_APPSETTINGS_DIR}
    cd ${SEGMENT_APPSETTINGS_DIR}
fi

if [[ ("${REFERENCE_OPERATION}" == "${REFERENCE_OPERATION_LISTFULL}") ]]; then
    # Update the deployment unit list with all deployment units
    DEPLOYMENT_UNIT_ARRAY=()
    for BUILD_FILE in $(find . -name "build.*"); do
        DEPLOYMENT_UNIT_ARRAY+=("$(basename $(dirname ${BUILD_FILE}))")
    done
fi

# Process each deployment unit
for ((INDEX=0; INDEX<${#DEPLOYMENT_UNIT_ARRAY[@]}; INDEX++)); do

    # Next deployment unit to process
    CURRENT_DEPLOYMENT_UNIT="${DEPLOYMENT_UNIT_ARRAY[${INDEX}]}"
    CODE_COMMIT="${CODE_COMMIT_ARRAY[${INDEX}]:-?}"
    CODE_TAG="${CODE_TAG_ARRAY[${INDEX}]:-?}"
    CODE_REPO="${CODE_REPO_ARRAY[${INDEX}]:-?}"
    CODE_PROVIDER="${CODE_PROVIDER_ARRAY[${INDEX}]:-?}"
    IMAGE_FORMATS="${IMAGE_FORMATS_ARRAY[${INDEX}]:-?}"
    IFS="${IMAGE_FORMAT_SEPARATORS}" read -ra CODE_IMAGE_FORMATS_ARRAY <<< "${IMAGE_FORMATS}"

    # Look for the deployment unit and build reference files
    EFFECTIVE_DEPLOYMENT_UNIT="${CURRENT_DEPLOYMENT_UNIT}"
    for REF_FILE in deployment_unit.ref slice.ref; do
        DEPLOYMENT_UNIT_FILE="${CURRENT_DEPLOYMENT_UNIT}/${REF_FILE}"
        if [[ -f "${DEPLOYMENT_UNIT_FILE}" ]]; then
            EFFECTIVE_DEPLOYMENT_UNIT=$(cat "${DEPLOYMENT_UNIT_FILE}")
            break
        fi
    done
    NEW_BUILD_FILE="${EFFECTIVE_DEPLOYMENT_UNIT}/build.json"
    BUILD_FILE="${NEW_BUILD_FILE}"
    if [[ ! -f "${BUILD_FILE}" ]]; then
        # Legacy file naming
        LEGACY_BUILD_FILE="${EFFECTIVE_DEPLOYMENT_UNIT}/build.ref"
        BUILD_FILE="${LEGACY_BUILD_FILE}"
    fi
    
    # Ensure appsettings directories exist
    if [[ -n "${SEGMENT_APPSETTINGS_DIR}" ]]; then
        mkdir -p "${CURRENT_DEPLOYMENT_UNIT}" "${EFFECTIVE_DEPLOYMENT_UNIT}"
    fi

    case ${REFERENCE_OPERATION} in
        ${REFERENCE_OPERATION_ACCEPT})
            # Tag builds with an acceptance tag
            if [[ "${IMAGE_FORMATS}" != "?" ]]; then
                for IMAGE_FORMAT in "${CODE_IMAGE_FORMATS_ARRAY[@]}"; do
                    IMAGE_PROVIDER_VAR="PRODUCT_${IMAGE_FORMAT^^}_PROVIDER"
                    IMAGE_PROVIDER="${!IMAGE_PROVIDER_VAR}"
                    IMAGE_FORMAT_LOWER=${IMAGE_FORMAT,,}
                    case ${IMAGE_FORMAT_LOWER} in
                        docker)
                            ${AUTOMATION_DIR}/manage${IMAGE_FORMAT_LOWER^}.sh -k -a "${IMAGE_PROVIDER}" \
                                -s "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}" -r "${ACCEPTANCE_TAG}"
                            RESULT=$?
                            if [[ "${RESULT}" -ne 0 ]]; then exit; fi
                            ;;
                        lambda|swagger|cloudfront)
                            ${AUTOMATION_DIR}/manage${IMAGE_FORMAT_LOWER^}.sh -k -a "${IMAGE_PROVIDER}" \
                                -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}" -r "${ACCEPTANCE_TAG}"
                            RESULT=$?
                            if [[ "${RESULT}" -ne 0 ]]; then exit; fi
                            ;;
                        *)
                            echo -e "\nUnknown image format \"${IMAGE_FORMAT}\"" >&2
                            exit
                            ;;
                    esac
                done
            fi
            ;;

        ${REFERENCE_OPERATION_LIST})
            # Add build info to DETAIL_MESSAGE
            updateDetail "${CURRENT_DEPLOYMENT_UNIT}" "${CODE_COMMIT}" "${CODE_TAG}" "${IMAGE_FORMATS}"
            ;;
    
        ${REFERENCE_OPERATION_LISTFULL})
            if [[ -f ${BUILD_FILE} ]]; then
                getBuildReferenceParts "$(cat ${BUILD_FILE})"
                if [[ "${BUILD_REFERENCE_COMMIT}" != "?" ]]; then
                    # Update arrays
                    if [[ "${EFFECTIVE_DEPLOYMENT_UNIT}" == "${CURRENT_DEPLOYMENT_UNIT}" ]]; then
                        CODE_COMMIT_ARRAY["${INDEX}"]="${BUILD_REFERENCE_COMMIT}"
                        CODE_TAG_ARRAY["${INDEX}"]="${BUILD_REFERENCE_TAG}"
                        IMAGE_FORMATS_ARRAY["${INDEX}"]="${BUILD_REFERENCE_FORMATS}"
                    fi
                fi
            fi            
            ;;

        ${REFERENCE_OPERATION_UPDATE})
            # Ensure something to do for the current deployment unit
            if [[ "${CODE_COMMIT}" == "?" ]]; then continue; fi
            if [[ "${EFFECTIVE_DEPLOYMENT_UNIT}" != "${CURRENT_DEPLOYMENT_UNIT}" ]]; then
                echo -e "\nIgnoring the \"${CURRENT_DEPLOYMENT_UNIT}\" deployment unit - it contains a reference to the \"${EFFECTIVE_DEPLOYMENT_UNIT}\" deployment unit"
                continue
            fi
        
            # Preserve the format if none provided
            if [[ ("${IMAGE_FORMATS}" == "?") &&
                    (-f ${NEW_BUILD_FILE}) ]]; then
                getBuildReferenceParts "$(cat ${NEW_BUILD_FILE})"
                IMAGE_FORMATS="${BUILD_REFERENCE_FORMATS}"
            fi
            
            # Construct the build reference
            formatBuildReference "${CODE_COMMIT}" "${CODE_TAG}" "${IMAGE_FORMATS}"
        
            # Update the build reference
            # Use newer naming and clean up legacy named build reference files
            echo -n "${BUILD_REFERENCE}" > "${NEW_BUILD_FILE}"
            if [[ -e "${LEGACY_BUILD_FILE}" ]]; then
                rm "${LEGACY_BUILD_FILE}"
            fi
            ;;
    
        ${REFERENCE_OPERATION_VERIFY})
            # Ensure code repo defined if tag provided only if commit not provided
            if [[ "${CODE_COMMIT}" == "?" ]]; then
                if [[ "${CODE_TAG}" != "?" ]]; then
                    if [[ "${EFFECTIVE_DEPLOYMENT_UNIT}" != "${CURRENT_DEPLOYMENT_UNIT}" ]]; then
                        echo -e "\nIgnoring the \"${CURRENT_DEPLOYMENT_UNIT}\" deployment unit - it contains a reference to the \"${EFFECTIVE_DEPLOYMENT_UNIT}\" deployment unit"
                        continue
                    fi
                    if [[ ("${CODE_REPO}" == "?") ||
                            ("${CODE_PROVIDER}" == "?") ]]; then
                        echo -e "\nIgnoring tag for the \"${CURRENT_DEPLOYMENT_UNIT}\" deployment unit - no code repo and/or provider defined"
                        continue
                    fi
                    # Determine the details of the provider hosting the code repo
                    defineGitProviderAttributes "${CODE_PROVIDER}" "CODE"
                    # Get the commit corresponding to the tag
                    TAG_COMMIT=$(git ls-remote -t https://${!CODE_CREDENTIALS_VAR}@${CODE_DNS}/${CODE_ORG}/${CODE_REPO} \
                                    "${CODE_TAG}" | cut -f 1)
                    CODE_COMMIT=$(git ls-remote -t https://${!CODE_CREDENTIALS_VAR}@${CODE_DNS}/${CODE_ORG}/${CODE_REPO} \
                                    "${CODE_TAG}^{}" | cut -f 1)
                    if [[ -z "${CODE_COMMIT}" ]]; then
                        echo -e "\nTag ${CODE_TAG} not found in the ${CODE_REPO} repo. Was an annotated tag used?" >&2
                        exit
                    fi
                    
                    # Fetch other info about the tag
                    # We are using a github api here to avoid having to pull in the whole repo - 
                    # git currently doesn't have a command to query the message of a remote tag
                    CODE_TAG_MESSAGE=$(curl -s https://${!CODE_CREDENTIALS_VAR}@${CODE_API_DNS}/repos/${CODE_ORG}/${CODE_REPO}/git/tags/${TAG_COMMIT} | jq .message | tr -d '"')
                    if [[ (-z "${CODE_TAG_MESSAGE}") || ("${CODE_TAG_MESSAGE}" == "Not Found") ]]; then
                        echo -e "\nMessage for tag ${CODE_TAG} not found in the ${CODE_REPO} repo" >&2
                        exit
                    fi
                    # else
                    # TODO: Confirm commit is in remote repo - for now we'll assume its there if an image exists
                else
                    # Nothing to do for this deployment unit
                    # Note that it is permissible to not have a tag for a deployment unit
                    # that is associated with a code repo. This situation arises
                    # if application settings are changed and a new release is 
                    # thus required.
                    continue
                fi
            fi
            
            # If no formats explicitly defined, use those in the build reference if defined
            if [[ ("${IMAGE_FORMATS}" == "?") &&
                    (-f ${NEW_BUILD_FILE}) ]]; then
                getBuildReferenceParts "$(cat ${NEW_BUILD_FILE})"
                IMAGE_FORMATS="${BUILD_REFERENCE_FORMATS}"
                IFS="${IMAGE_FORMAT_SEPARATORS}" read -ra CODE_IMAGE_FORMATS_ARRAY <<< "${IMAGE_FORMATS}"
            fi

            # Confirm the commit built successfully into an image
            if [[ "${IMAGE_FORMATS}" != "?" ]]; then
                for IMAGE_FORMAT in "${CODE_IMAGE_FORMATS_ARRAY[@]}"; do
                    IMAGE_PROVIDER_VAR="PRODUCT_${IMAGE_FORMAT^^}_PROVIDER"
                    IMAGE_PROVIDER="${!IMAGE_PROVIDER_VAR}"
                    FROM_IMAGE_PROVIDER_VAR="FROM_PRODUCT_${IMAGE_FORMAT^^}_PROVIDER"
                    FROM_IMAGE_PROVIDER="${!FROM_IMAGE_PROVIDER_VAR}"
                    case ${IMAGE_FORMAT,,} in
                        docker)
                            ${AUTOMATION_DIR}/manageDocker.sh -v -a "${IMAGE_PROVIDER}" -s "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"
                            RESULT=$?
                            ;;
                        lambda)
                            ${AUTOMATION_DIR}/manageLambda.sh -v -a "${IMAGE_PROVIDER}" -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"
                            RESULT=$?
                            ;;
                        swagger)
                            ${AUTOMATION_DIR}/manageSwagger.sh -v -a "${IMAGE_PROVIDER}" -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"
                            RESULT=$?
                            ;;
                        cloudfront)
                            ${AUTOMATION_DIR}/manageCloudFront.sh -v -a "${IMAGE_PROVIDER}" -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"
                            RESULT=$?
                            ;;
                        *)
                            echo -e "\nUnknown image format \"${IMAGE_FORMAT}\"" >&2
                            exit
                            ;;
                    esac
                    if [[ "${RESULT}" -ne 0 ]]; then
                        if [[ -n "${FROM_IMAGE_PROVIDER}" ]]; then
                            # Attempt to pull image in from remote provider
                            case ${IMAGE_FORMAT,,} in
                                docker)
                                    ${AUTOMATION_DIR}/manageDocker.sh -p -a "${IMAGE_PROVIDER}" -s "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"  -r "${VERIFICATION_TAG}" -z "${FROM_IMAGE_PROVIDER}"
                                    RESULT=$?
                                    ;;
                                lambda)
                                    ${AUTOMATION_DIR}/manageLambda.sh -p -a "${IMAGE_PROVIDER}" -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"  -r "${VERIFICATION_TAG}" -z "${FROM_IMAGE_PROVIDER}"
                                    RESULT=$?
                                    ;;
                                swagger)
                                    ${AUTOMATION_DIR}/manageSwagger.sh -x -p -a "${IMAGE_PROVIDER}" -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"  -r "${VERIFICATION_TAG}" -z "${FROM_IMAGE_PROVIDER}"
                                    RESULT=$?
                                    ;;
                                cloudfront)
                                    ${AUTOMATION_DIR}/manageCloudFront.sh -p -a "${IMAGE_PROVIDER}" -u "${CURRENT_DEPLOYMENT_UNIT}" -g "${CODE_COMMIT}"  -r "${VERIFICATION_TAG}" -z "${FROM_IMAGE_PROVIDER}"
                                    RESULT=$?
                                    ;;
                                *)
                                    echo -e "\nUnknown image format \"${IMAGE_FORMAT}\"" >&2
                                    exit
                                    ;;
                            esac
                            if [[ "${RESULT}" -ne 0 ]]; then
                                echo -e "\nUnable to pull ${IMAGE_FORMAT,,} image for deployment unit ${CURRENT_DEPLOYMENT_UNIT} and commit ${CODE_COMMIT} from provider ${FROM_IMAGE_PROVIDER}. Was the build successful?" >&2
                                exit
                            fi
                        else
                            echo -e "\n${IMAGE_FORMAT^} image for deployment unit ${CURRENT_DEPLOYMENT_UNIT} and commit ${CODE_COMMIT} not found. Was the build successful?" >&2
                            exit
                        fi
                    fi
                done
            fi

            # Save details of this deployment unit
            CODE_COMMIT_ARRAY[${INDEX}]="${CODE_COMMIT}"
            ;;

    esac
done

# Capture any changes to context
case ${REFERENCE_OPERATION} in
    ${REFERENCE_OPERATION_LIST})
        echo "DETAIL_MESSAGE=${DETAIL_MESSAGE}" >> ${AUTOMATION_DATA_DIR}/context.properties
        ;;

    ${REFERENCE_OPERATION_LISTFULL})
        echo "DEPLOYMENT_UNIT_LIST=${DEPLOYMENT_UNIT_ARRAY[@]}" >> ${AUTOMATION_DATA_DIR}/context.properties
        echo "CODE_COMMIT_LIST=${CODE_COMMIT_ARRAY[@]}" >> ${AUTOMATION_DATA_DIR}/context.properties
        echo "CODE_TAG_LIST=${CODE_TAG_ARRAY[@]}" >> ${AUTOMATION_DATA_DIR}/context.properties
        echo "IMAGE_FORMATS_LIST=${IMAGE_FORMATS_ARRAY[@]}" >> ${AUTOMATION_DATA_DIR}/context.properties
        echo "DETAIL_MESSAGE=${DETAIL_MESSAGE}" >> ${AUTOMATION_DATA_DIR}/context.properties
        ;;

    ${REFERENCE_OPERATION_VERIFY})
        echo "CODE_COMMIT_LIST=${CODE_COMMIT_ARRAY[@]}" >> ${AUTOMATION_DATA_DIR}/context.properties
        ;;

esac

# All good
RESULT=0