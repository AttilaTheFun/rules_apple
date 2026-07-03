#!/bin/bash
#
# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# environment_plist generates a plist file that contains some
# environment variables of the host machine (like DTPlatformBuild
# or BuildMachineOSBuild) given a target platform.
#
# This script only runs on darwin and you must have Xcode installed.
#
# --output    - the path to place the output plist file.
# --platform  - the target platform, e.g. 'iphoneos' or 'iphonesimulator8.3'
#

set -eu

while [[ $# > 1 ]]
do
key="$1"

case $key in
  --platform)
    PLATFORM="$2"
    shift
    ;;
  --output)
    OUTPUT="$2"
    shift
    ;;
  *)
    # unknown option
    ;;
esac
shift
done

os_build=$(sw_vers -buildVersion)

set +e
PLATFORM_DIR=$(/usr/bin/xcrun --sdk "${PLATFORM}" --show-sdk-platform-path 2>/dev/null)
XCRUN_EXITCODE=$?
set -e
if [[ ${XCRUN_EXITCODE} -eq 0 ]] ; then
  # A full Xcode installation (or Xcode-style developer directory) is
  # available; read the environment values from the platform's Info.plist and
  # xcodebuild.
  PLATFORM_PLIST="${PLATFORM_DIR}"/Info.plist
  compiler=$(/usr/libexec/PlistBuddy -c "Print :DefaultProperties:DEFAULT_COMPILER" "${PLATFORM_PLIST}")
  xcodebuild_version_sdk_output=$(/usr/bin/xcrun xcodebuild -version -sdk "${PLATFORM}" 2>/dev/null)
  xcodebuild_version_output=$(/usr/bin/xcrun xcodebuild -version 2>/dev/null)
  # Parses 'PlatformVersion N.N' into N.N.
  platform_version=$(echo "${xcodebuild_version_sdk_output}" | grep PlatformVersion | cut -d ' ' -f2)
  # Parses 'ProductBuildVersion NNNN' into NNNN.
  sdk_build=$(echo "${xcodebuild_version_sdk_output}" | grep ProductBuildVersion | cut -d ' ' -f2)
  platform_build=$"${sdk_build}"
  # Parses 'Build version NNNN' into NNNN.
  xcode_build=$(echo "${xcodebuild_version_output}" | grep Build | cut -d ' ' -f3)
  # Parses 'Xcode N.N' into N.N.
  xcode_version_string=$(echo "${xcodebuild_version_output}" | grep Xcode | cut -d ' ' -f2)
  # Converts '7.1' -> 0710, and '7.1.1' -> 0711.
  xcode_version=$(/usr/bin/printf '%02d%d%d\n' $(echo "${xcode_version_string//./ }"))
else
  # There is no platform directory. This happens with Command Line Tools
  # style developer directories, such as hermetic toolchains assembled from
  # the Command Line Tools and a vendored SDK, which have no Platforms
  # directory and no xcodebuild. Derive the values from the SDK itself; the
  # Xcode version and build cannot be known without an Xcode installation, so
  # those fields are left empty.
  set +e
  SDK_DIR=$(/usr/bin/xcrun --sdk "${PLATFORM}" --show-sdk-path 2>/dev/null)
  XCRUN_EXITCODE=$?
  set -e
  if [[ ${XCRUN_EXITCODE} -ne 0 ]] ; then
    echo "environment_plist: SDK not located. This may indicate that the \
xcode and SDK version pair is not available."
    # Since this already failed, assume this is going to fail again. With
    # set -e, this will produce the appropriate stderr and error code.
    /usr/bin/xcrun --sdk "${PLATFORM}" --show-sdk-path 2>&1
  fi
  SDK_SETTINGS="${SDK_DIR}/SDKSettings.plist"
  SDK_SYSTEM_VERSION="${SDK_DIR}/System/Library/CoreServices/SystemVersion.plist"
  compiler=$(/usr/libexec/PlistBuddy -c "Print :DefaultProperties:DEFAULT_COMPILER" "${SDK_SETTINGS}" 2>/dev/null || echo "")
  platform_version=$(/usr/libexec/PlistBuddy -c "Print :Version" "${SDK_SETTINGS}" 2>/dev/null || echo "")
  sdk_build=$(/usr/libexec/PlistBuddy -c "Print :ProductBuildVersion" "${SDK_SYSTEM_VERSION}" 2>/dev/null || echo "")
  platform_build=$"${sdk_build}"
  xcode_build=""
  xcode_version=""
fi

TEMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/bazel_environment.XXXXXX")
PLIST="${TEMPDIR}/env.plist"
trap 'rm -rf "${TEMPDIR}"' ERR EXIT

/usr/libexec/PlistBuddy \
    -c "Add :DTPlatformBuild string ${platform_build:-""}" \
    -c "Add :DTSDKBuild string ${sdk_build:-""}" \
    -c "Add :DTPlatformVersion string ${platform_version:-""}" \
    -c "Add :DTXcode string ${xcode_version:-""}" \
    -c "Add :DTXcodeBuild string ${xcode_build:-""}" \
    -c "Add :DTCompiler string ${compiler:-""}" \
    -c "Add :BuildMachineOSBuild string ${os_build:-""}" \
    "$PLIST" > /dev/null

plutil -convert binary1 -o "${OUTPUT}" -s  -- "${PLIST}"
