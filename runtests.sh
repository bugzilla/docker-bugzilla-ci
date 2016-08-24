#!/bin/bash
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

BUILDBOT=/docker/buildbot_step

if [ -z "$TEST_SUITE" ]; then
    TEST_SUITE=sanity
fi

set -e

# Output to log file as well as STDOUT/STDERR
exec > >(tee /tmp/runtests.log) 2>&1

echo "== Retrieving Bugzilla code"
echo "Checking out $GITHUB_BASE_GIT $GITHUB_BASE_BRANCH ..."
mv $BUGZILLA_ROOT ${BUGZILLA_ROOT}.back
git clone $GITHUB_BASE_GIT --single-branch --depth 1 --branch $GITHUB_BASE_BRANCH $BUGZILLA_ROOT
cd $BUGZILLA_ROOT
ln -sf $BUGZILLA_LIB local
if [ "$GITHUB_BASE_REV" != "" ]; then
    echo "Switching to revision $GITHUB_BASE_REV ..."
    git checkout -q $GITHUB_BASE_REV
fi

if [ "$TEST_SUITE" = "docs" ]; then
    cd $BUGZILLA_ROOT/docs
    /bin/bash $BUILDBOT "Documentation" perl makedocs.pl --with-pdf
    exit $?
fi

echo -e "\n== Starting database"
/usr/bin/mysqld_safe &
sleep 5

echo -e "\n== Updating configuration"
mysql -u root mysql -e "CREATE DATABASE bugs_test CHARACTER SET = 'utf8';" || exit 1
mysql -u root mysql -e "GRANT ALL PRIVILEGES ON bugs_test.* TO bugs@'%' IDENTIFIED BY 'bugs'; FLUSH PRIVILEGES;" || exit 1
sed -e "s?%DB%?$BUGS_DB_DRIVER?g" --in-place xt/config/checksetup_answers.txt
echo "\$answer{'memcached_servers'} = 'localhost:11211';" >> xt/config/checksetup_answers.txt

echo -e "\n== Running checksetup"
cd $BUGZILLA_ROOT
perl checksetup.pl xt/config/checksetup_answers.txt
perl checksetup.pl xt/config/checksetup_answers.txt

if [ "$TEST_SUITE" = "sanity" ]; then
    cd $BUGZILLA_ROOT
    /bin/bash $BUILDBOT "Sanity" prove -f -v t/*.t
    exit $?
fi

echo -e "\n== Generating test data"
cd $BUGZILLA_ROOT/xt/config
perl generate_test_data.pl

echo -e "\n== Starting web server"
sed -e "s?^#Perl?Perl?" --in-place /etc/httpd/conf.d/bugzilla.conf
/usr/sbin/httpd &
sleep 3

echo -e "\n== Starting memcached"
/usr/bin/memcached -u memcached -d
sleep 3

cd $BUGZILLA_ROOT
if [ "$TEST_SUITE" = "selenium" ]; then
    export DISPLAY=:0

    # Setup dbus for Firefox
    dbus-uuidgen > /var/lib/dbus/machine-id

    echo -e "\n== Starting virtual frame buffer and vnc server"
    Xvnc $DISPLAY -screen 0 1280x1024x16 -ac -SecurityTypes=None \
         -extension RANDR 2>&1 | tee /tmp/xvnc.log &
    sleep 5

    echo -e "\n== Starting Selenium server"
    java -jar /docker/selenium-server.jar -log /tmp/selenium.log > /dev/null 2>&1 &
    sleep 5

    # Set NO_TESTS=1 if just want selenium services
    # but no tests actually executed.
    [ $NO_TESTS ] && exit 0

    /bin/bash $BUILDBOT "Selenium" prove -f -v xt/selenium/*.t
    exit $?
fi

if [ "$TEST_SUITE" = "webservices" ]; then
    /bin/bash $BUILDBOT "Webservices" prove -f -v xt/{rest,webservice}/*.t
    exit $?
fi