REM SPDX-FileCopyrightText: (C)  Basil Peace
REM SPDX-License-Identifier: Apache-2.0
mkdir build
cd build
rm *.zip
curl --user %ARTIFACTORY_USERNAME%:%ARTIFACTORY_PASSWORD% --output issues.zip https://fidata.jfrog.io/fidata/composer-local/fidata/mantisbt-0.1.0.zip
cd ..
