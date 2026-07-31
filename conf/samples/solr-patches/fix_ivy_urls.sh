#!/bin/bash
# Repoint the dead/HTTP-only Ivy repositories used by 2015-2019 Lucene/Solr to live HTTPS mirrors,
# so `ant compile-test` can resolve dependencies today. Called by build_solr*.sh.
# Run with cwd = the lucene-solr monorepo root.
#
# Version-independent: seds whatever lucene/*ivy-settings*.xml exist (file name differs by era), so
# it is safe to re-run after every `git checkout`. The first -e rewrites the `public` resolver, which
# is defined inside the ivy jar and can't be reached any other way.
set -e
find lucene -name '*ivy-settings*.xml' -exec sed -i \
  -e 's|.*ivysettings-public\.xml.*|  <resolvers><ibiblio name="public" root="https://repo1.maven.org/maven2" m2compatible="true"/></resolvers>|' \
  -e 's|http://uk.maven.org/maven2|https://repo1.maven.org/maven2|g' \
  -e 's|http://maven.restlet.org|https://maven.restlet.talend.com|g' \
  -e 's|http://repository.cloudera.com|https://repository.cloudera.com|g' \
  -e 's|http://maven.tmatesoft.com|https://maven.tmatesoft.com|g' \
  {} +
echo "[fix_ivy_urls] repointed Ivy repositories to live HTTPS mirrors"
