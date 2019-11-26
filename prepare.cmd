setlocal
rm --force --recursive mantisbt-*

set MANTIS_BT_VERSION=2.22.1
unzip mantisbt.zip
set DIR_NAME=mantisbt-%MANTIS_BT_VERSION%
rm --force %DIR_NAME%/config/config_inc.php.sample
rm --force --recursive %DIR_NAME%/admin
cp --recursive config %DIR_NAME%

unzip source-integration.zip
cp --recursive source-integration-2.3.0/Source %DIR_NAME%/plugins
cp --recursive source-integration-2.3.0/SourceGithub %DIR_NAME%/plugins

unzip ApiExtend.zip -d %DIR_NAME%/plugins

cp --recursive .ebextensions %DIR_NAME%

rm --force issues.zip
cd %DIR_NAME%
zip -r ../issues.zip *
cd ..

endlocal
