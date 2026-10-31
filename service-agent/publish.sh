#!/usr/bin/env bash
# Pushes the service agent image from the build job's OCI tarball to the
# registry of an image reference, pulls it back by its digest and checks that
# the registry serves the image the build job saved (README.md, "The image").
# The service-agent workflow's image-publish job runs it on a release tag, and
# its image-publish-rehearsal job, with REHEARSE=1, against a registry on the
# job's own loopback address.
#
# Usage: publish.sh check REFERENCE
#        publish.sh push REFERENCE TARBALL SHA256 DIGEST_FILE
#
# check checks the image reference alone: a registry host and a repository,
# without a tag or digest, and with REHEARSE=1 a host that is the loopback
# address with a port. push checks it again, then the tarball against SHA256,
# the build job's, and its image's labels; it tags the image with its version
# label and service-agent and pushes both. The version must be a release tag;
# with REHEARSE=1 it may instead be the commit, as build.sh labels a build
# outside a tag. DIGEST_FILE gets one line, the pushed image as
# REFERENCE@sha256:..., which the publish job also gives as its output
# `pinned`.
set -euo pipefail

usage="usage: publish.sh check REFERENCE | publish.sh push REFERENCE TARBALL SHA256 DIGEST_FILE"
cmd=${1:-}
ref=${2:?$usage}
case $cmd in
check) ;;
push)
	tar=${3:?$usage}
	want=${4:-}
	digest_file=${5:?$usage}
	commit=${GITHUB_SHA:?set GITHUB_SHA, the commit the image was built from}
	;;
*)
	echo "$usage" >&2
	exit 2
	;;
esac
summary=${GITHUB_STEP_SUMMARY:-/dev/null}
rehearse=${REHEARSE:-}
loaded=toshi-service-agent:latest

fail() {
	echo "::error::$*"
	exit 1
}
label() {
	docker image inspect -f "{{index .Config.Labels \"org.opencontainers.image.$2\"}}" "$1"
}

# The push adds the tags, so the reference has neither a tag nor a digest, and
# its first part is the registry host the push goes to.
host=${ref%%/*}
name=${ref##*/}
if [[ $ref != */* || ($host != *.* && $host != *:* && $host != localhost) ]]; then
	fail "the image reference '${ref}' does not start with a registry host"
fi
if [[ -z $name ]]; then
	fail "the image reference '${ref}' names no repository after its registry host"
fi
if [[ $name == *[:@]* ]]; then
	fail "the image reference '${ref}' has a tag or digest; give it without one"
fi
# A rehearsal pushes only to the registry it started on the loopback address,
# before anything is pushed.
if [[ -n $rehearse && ! $host =~ ^(127\.0\.0\.1|localhost):[0-9]+$ ]]; then
	fail "a rehearsal pushes only to the job's own registry on the loopback address, not to ${host}"
fi
if [[ -n $rehearse ]]; then
	echo "image reference ${ref}, registry ${host}: the job's own, on the loopback address"
else
	echo "image reference ${ref}, registry ${host}"
fi

if [[ $cmd == check ]]; then
	exit 0
fi

got=$(sha256sum "$tar" | cut -d' ' -f1)
if [[ -z $want || $got != "$want" ]]; then
	fail "the OCI tarball is ${got}, the build job saved ${want:-nothing}"
fi
docker load -i "$tar"
id=$(docker image inspect -f '{{.Id}}' "$loaded")
version=$(label "$loaded" version)
revision=$(label "$loaded" revision)
if [[ $revision != "$commit" ]]; then
	fail "the image's revision label is '${revision}', the run's commit ${commit}"
fi
if [[ $version =~ ^v[0-9A-Za-z._-]+$ ]]; then
	:
elif [[ -n $rehearse && ${#version} -ge 7 && $commit == "$version"* ]]; then
	echo "version ${version} is the commit: a build outside a release tag"
else
	fail "the image's version '${version}' is not a release tag"
fi
echo "loaded image ${id}, version ${version}, revision ${revision}"

# Both tags must point at one digest, the one the push reports.
digest=
for t in "$version" service-agent; do
	docker tag "$loaded" "${ref}:${t}"
	out=$(docker push "${ref}:${t}")
	printf '%s\n' "$out"
	d=$(grep -oE 'digest: sha256:[0-9a-f]{64}' <<<"$out" | tail -n1 | cut -d' ' -f2)
	if [[ -z $d ]]; then
		fail "the push of ${ref}:${t} reported no digest"
	fi
	if [[ -n $digest && $d != "$digest" ]]; then
		fail "${ref}:${t} was pushed as ${d}, ${ref}:${version} as ${digest}"
	fi
	digest=$d
done

# Pull it back by its digest, with no copy left on the host, and compare it
# with the image loaded from the tarball.
docker image rm "${ref}:${version}" "${ref}:service-agent" "$loaded" >/dev/null
docker pull "${ref}@${digest}"
pulled=$(docker image inspect -f '{{.Id}}' "${ref}@${digest}")
if [[ $pulled != "$id" ]]; then
	fail "${ref}@${digest} pulled back as image ${pulled}, the tarball loaded as ${id}"
fi
if [[ $(label "${ref}@${digest}" version) != "$version" || $(label "${ref}@${digest}" revision) != "$revision" ]]; then
	fail "${ref}@${digest} pulled back with other labels than the tarball's"
fi

printf '%s\n' "${ref}@${digest}" >"$digest_file"
echo "pinned=${ref}@${digest}" >>"${GITHUB_OUTPUT:-/dev/null}"
{
	echo "pushed ${ref}:${version} and :service-agent, digest ${digest}"
	echo "pulled back by digest: image ${id}, version ${version}, revision ${revision}, from the OCI tarball with sha256 ${want}"
	echo "pushed reference: ${ref}@${digest}"
} | tee -a "$summary"
