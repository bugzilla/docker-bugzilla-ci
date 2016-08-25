# This Source Code Form is subject to the terms of the Mozilla Public
# License, v. 2.0. If a copy of the MPL was not distributed with this
# file, You can obtain one at http://mozilla.org/MPL/2.0/.
#
# This Source Code Form is "Incompatible With Secondary Licenses", as
# defined by the Mozilla Public License, v. 2.0.

FROM bugzilla/bugzilla-base
MAINTAINER David Lawrence <dkl@mozilla.com>

# Environment configuration
ENV BUGZILLA_USER bugzilla
ENV BUGZILLA_ROOT /home/$BUGZILLA_USER/devel/htdocs/bugzilla
ENV BUGS_DB_DRIVER mysql
ENV GITHUB_BASE_GIT https://github.com/bugzilla/bugzilla
ENV GITHUB_BASE_BRANCH master

# Distribution package installation
COPY rpm_list /docker/
RUN yum -y install `cat /docker/rpm_list` && \
    yum clean all

# User configuration
RUN useradd -m -G wheel -u 1000 -s /bin/bash $BUGZILLA_USER \
    && passwd -u -f $BUGZILLA_USER \
    && echo "bugzilla:bugzilla" | chpasswd

# Apache configuration
COPY bugzilla.conf /etc/httpd/conf.d/bugzilla.conf
RUN chown root.root /etc/httpd/conf.d/bugzilla.conf && \
    chmod 440 /etc/httpd/conf.d/bugzilla.conf

# MySQL pre-configuration
COPY my.cnf /etc/my.cnf
RUN chmod 644 /etc/my.cnf && \
    chown root.root /etc/my.cnf && \
    rm -rf /etc/mysql && \
    rm -rf /var/lib/mysql/*

# Clone the code repo initially
RUN su $BUGZILLA_USER -c "git clone $GITHUB_BASE_GIT -b $GITHUB_BASE_BRANCH $BUGZILLA_ROOT"
RUN ln -sf $BUGZILLA_LIB $BUGZILLA_ROOT/local

# Bugzilla dependencies and setup
ADD https://raw.githubusercontent.com/miyagawa/cpanminus/master/cpanm /usr/local/bin/cpanm
RUN chmod 755 /usr/local/bin/cpanm
RUN cpanm -l $BUGZILLA_LIB  --quiet --notest Test::WWW::Selenium && rm -rf ~/.cpanm
COPY buildbot_step checksetup_answers.txt *.sh /docker/
RUN chmod 755 /docker/*.sh
RUN /docker/bugzilla_config.sh
RUN pip install rst2pdf

# Final permissions fix
RUN chown -R $BUGZILLA_USER.$BUGZILLA_USER /home/$BUGZILLA_USER

# Networking
RUN echo "NETWORKING=yes" > /etc/sysconfig/network
EXPOSE 80
EXPOSE 5900

# Testing scripts for CI
ADD https://selenium-release.storage.googleapis.com/2.53/selenium-server-standalone-2.53.0.jar /docker/selenium-server.jar

# Supervisor
COPY supervisord.conf /etc/supervisord.conf
RUN chmod 700 /etc/supervisord.conf
CMD ["/usr/bin/supervisord", "-c", "/etc/supervisord.conf"]
