#!/bin/bash -e
# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

QA_DIR=xt

if [ -z "$TEST_SUITE" ]; then
    TEST_SUITE=sanity
fi

# Output to log file as well as STDOUT/STDERR
exec > >(tee /tmp/runtests.log) 2>&1

echo "== Retrieving Bugzilla code"
echo "Checking out $GITHUB_BASE_GIT $GITHUB_BASE_BRANCH ..."
git clone $GITHUB_BASE_GIT --single-branch --depth 1 --branch $GITHUB_BASE_BRANCH $BUGZILLA_WWW
cd $BUGZILLA_WWW
ln -sf $BUGZILLA_LIB local
if [ "$GITHUB_BASE_REV" != "" ]; then
    echo "Switching to revision $GITHUB_BASE_REV ..."
    git checkout -q $GITHUB_BASE_REV
fi

if [ "$GITHUB_BASE_BRANCH" != "master" ]; then
    echo -e "\n== Checking out QA tests"
    QA_DIR=qa
    export PERL5LIB=$BUGZILLA_LIB/lib/perl5
    git clone https://github.com/bugzilla/qa --single-branch --depth 1 --branch $GITHUB_BASE_BRANCH $QA_DIR
fi

if [ "$TEST_SUITE" = "docs" ]; then
    MAKEDOCS_ARGS="--with-pdf"
    cd $BUGZILLA_WWW/docs
    if [ "$GITHUB_BASE_BRANCH" = "4.4" ]; then
        MAKEDOCS_ARGS=""
    fi
    buildbot_step "Documentation" perl makedocs.pl $MAKEDOCS_ARGS
    exit $?
fi

echo -e "\n== Starting database"
if [ "$BUGS_DB_DRIVER" = "mysql" ]; then
    /usr/bin/mysqld_safe &
    sleep 5
    mysql -u root mysql -e "GRANT ALL PRIVILEGES ON *.* TO bugs@localhost IDENTIFIED BY 'bugs'; FLUSH PRIVILEGES;" || exit 1
    mysql -u root mysql -e "CREATE DATABASE bugs_test CHARACTER SET = 'utf8';" || exit 1
    mysql -u root mysql -e "GRANT ALL PRIVILEGES ON bugs_test.* TO bugs@'%' IDENTIFIED BY 'bugs'; FLUSH PRIVILEGES;" || exit 1
elif [ "$BUGS_DB_DRIVER" = "pg" ]; then
    su postgres -c "/usr/bin/pg_ctl -D /var/lib/pgsql/data start" || exit 1
    sleep 5
    su postgres -c "createuser --superuser bugs" || exit 1
    su postgres -c "psql -U postgres -d postgres -c \"alter user bugs with password 'bugs';\"" || exit 1
    su postgres -c "psql -U postgres -d postgres -c \"create database bugs_test owner bugs template template0 encoding 'utf8';\"" || exit 1
elif [ "$BUGS_DB_DRIVER" = "sqlite" ]; then
    echo -e "Sqlite DB selected"
else
    echo -e "BUGS_DB_DRIVER not set correctly"
    exit 1
fi

echo -e "\n== Updating configuration"
sed -e "s?%DB%?$BUGS_DB_DRIVER?g" --in-place $QA_DIR/config/checksetup_answers.txt
sed -e "s?%DB_NAME%?bugs_test?g" --in-place $QA_DIR/config/checksetup_answers.txt
sed -e "s?%USER%?$BUGZILLA_USER?g" --in-place $QA_DIR/config/checksetup_answers.txt
echo "\$answer{'memcached_servers'} = 'localhost:11211';" >> $QA_DIR/config/checksetup_answers.txt
echo "\$answer{'apache_size_limit'} = 700000;" >> $QA_DIR/config/checksetup_answers.txt

echo -e "\n== Running checksetup"
perl checksetup.pl $QA_DIR/config/checksetup_answers.txt
perl checksetup.pl $QA_DIR/config/checksetup_answers.txt

if [ "$TEST_SUITE" = "sanity" ]; then
    buildbot_step "Sanity" prove -f -v t/*.t
    exit $?
fi

echo -e "\n== Generating test data"
cd $BUGZILLA_WWW/$QA_DIR/config
perl generate_test_data.pl

echo -e "\n== Starting web server"
/usr/sbin/httpd &
sleep 3

echo -e "\n== Starting memcached"
/usr/bin/memcached -u memcached -d
sleep 3

cd $BUGZILLA_WWW

if [ "$TEST_SUITE" = "selenium" ]; then
    export DISPLAY=:0

    # Setup dbus for Firefox
    dbus-uuidgen > /var/lib/dbus/machine-id

    echo -e "\n== Starting virtual frame buffer and vnc server"
    Xvnc $DISPLAY -screen 0 1280x1024x16 -ac -SecurityTypes=None \
         -extension RANDR 2>&1 | tee /tmp/xvnc.log &
    sleep 5

    echo -e "\n== Starting Selenium server"
    java -jar /selenium-server.jar -log /tmp/selenium.log > /dev/null 2>&1 &
    sleep 5

    # Set NO_TESTS=1 if just want selenium services
    # but no tests actually executed.
    [ $NO_TESTS ] && exit 0

    if [ "$GITHUB_BASE_BRANCH" = "master" ]; then
        buildbot_step "Selenium" prove -f -v $QA_DIR/selenium/*.t
    else
        cd $BUGZILLA_WWW/$QA_DIR/t
        buildbot_step "Selenium" prove -f -v test_*.t
    fi

    exit $?
fi

if [ "$TEST_SUITE" = "webservices" ]; then
    if [ "$GITHUB_BASE_BRANCH" = "master" ]; then
        buildbot_step "Webservices" prove -f -v $QA_DIR/{rest,webservice}/*.t
    else
        cd $BUGZILLA_WWW/$QA_DIR/t
        if [ "$GITHUB_BASE_BRANCH" = "5.0" ]; then
            buildbot_step "Webservices" prove -f -v rest_*.t
        fi
        buildbot_step "Webservices" prove -f -v webservice_*.t
    fi

    exit $?
fi
