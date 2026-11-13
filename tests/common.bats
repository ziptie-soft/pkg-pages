#!/usr/bin/env bats
# lib/common.sh and lib/packages.sh: input validation, escaping, temp directories, versions.
# Pure sh: runs anywhere.

load helpers

# sh_lib CODE: run CODE in sh with common.sh and packages.sh sourced.
sh_lib() {
    sh -c ". '$LIB/common.sh'; . '$LIB/packages.sh'; $1"
}

@test "check_name accepts Debian-style names" {
    for n in hello a0 star-forge lib.foo+bar 9to5; do
        run sh_lib "check_name name '$n'"
        assert_status 0
    done
}

@test "check_name rejects names unsafe in paths, URLs or HTML" {
    for n in '' Hello -lead .dot 'a b' 'a/b' 'a<b' 'a_b' "a'b"; do
        run sh_lib "check_name name \"$n\""
        assert_status 1
    done
}

@test "check_url accepts https and file:/// URLs" {
    for u in https://owner.github.io/repo https://example.com file:///tmp/site 'https://h/p?q=1&r=2'; do
        run sh_lib "check_url base-url '$u'"
        assert_status 0
    done
}

@test "check_url rejects other schemes and characters that need quoting" {
    for u in http://example.com ftp://x file://relative 'javascript:alert(1)' https:// \
        'https://a b' "https://a'b" 'https://a"b' 'https://a<b' 'https://$basearch' 'https://a\b'; do
        run sh -c ". '$LIB/common.sh'; check_url base-url \"\$1\"" sh "$u"
        assert_status 1
    done
}

@test "check_url rejects a multi-line URL" {
    run sh -c ". '$LIB/common.sh'; check_url base-url \"\$1\"" sh "https://a
https://b"
    assert_status 1
}

@test "check_base_url accepts site URLs" {
    for u in https://owner.github.io/repo https://pkgs.example.com file:///tmp/site \
        'https://h/a-b_c.d~e/%41+@=,'; do
        run sh -c ". '$LIB/common.sh'; check_base_url base-url \"\$1\"" sh "$u"
        assert_status 0
    done
}

@test "check_base_url refuses what a shell would interpret" {
    for u in 'https://h/p?q=1' 'https://h/a&b' 'https://h/a;b' 'https://h/(x)' \
        'https://h/a*' 'https://h/a!b' 'https://h/a#b' http://x; do
        run sh -c ". '$LIB/common.sh'; check_base_url base-url \"\$1\"" sh "$u"
        assert_status 1
    done
}

@test "check_relpath accepts relative paths and rejects absolute ones and .." {
    for p in site dist/x.rpm packaging/signing/repo.asc ./a 'a b/c' a..b; do
        run sh -c ". '$LIB/common.sh'; check_relpath p \"\$1\"" sh "$p"
        assert_status 0
    done
    for p in '' /etc/passwd .. ../x a/.. a/../b; do
        run sh -c ". '$LIB/common.sh'; check_relpath p \"\$1\"" sh "$p"
        assert_status 1
    done
}

@test "check_bool accepts only the strings true and false" {
    run sh_lib "check_bool b true"; assert_status 0
    run sh_lib "check_bool b false"; assert_status 0
    for v in '' yes 1 True TRUE; do
        run sh_lib "check_bool b '$v'"
        assert_status 1
    done
}

@test "check_word accepts APT tokens and rejects the rest" {
    run sh_lib "check_word suite stable"; assert_status 0
    run sh_lib "check_word arch x86_64"; assert_status 0
    run sh_lib "check_word suite 'a b'"; assert_status 1
    run sh_lib "check_word suite '../x'"; assert_status 1
}

@test "html_escape escapes the five HTML metacharacters" {
    run sh -c ". '$LIB/common.sh'; printf '%s' \"\$1\" | html_escape" sh "<a href=\"x\">'&'</a>"
    assert_status 0
    [ "$output" = "&lt;a href=&quot;x&quot;&gt;&#39;&amp;&#39;&lt;/a&gt;" ]
}

@test "die prints an annotation in Actions and plain text elsewhere" {
    run sh_lib "die boom"
    assert_status 1
    [ "$output" = "error: boom" ]
    GITHUB_ACTIONS=true run sh_lib "die boom"
    [ "$output" = "::error::boom" ]
}

@test "warning prints an annotation in Actions and plain text elsewhere" {
    run sh_lib "warning hi"
    assert_status 0
    [ "$output" = "warning: hi" ]
    GITHUB_ACTIONS=true run sh_lib "warning hi"
    assert_status 0
    [ "$output" = "::warning::hi" ]
}

@test "set_output and set_env append to the runner's files" {
    run sh_lib "set_output a 1; set_output b two; set_env C 3"
    assert_status 0
    [ "$(cat "$GITHUB_OUTPUT")" = "a=1
b=two" ]
    [ "$(cat "$GITHUB_ENV")" = "C=3" ]
}

@test "set_output does nothing outside Actions" {
    unset GITHUB_OUTPUT
    run sh_lib "set_output a 1"
    assert_status 0
}

@test "require_tools names every missing tool" {
    run sh_lib "require_tools sh no-such-tool-1 no-such-tool-2"
    assert_status 1
    assert_output_contains "no-such-tool-1 no-such-tool-2"
}

@test "make_tmpdir directories are removed on exit and on die" {
    run sh_lib "make_tmpdir d; echo \$d"
    assert_status 0
    [ -n "$output" ] && [ ! -e "$output" ]
    run sh_lib "make_tmpdir d; echo \$d > '$TMP/path'; die x"
    assert_status 1
    [ ! -e "$(cat "$TMP/path")" ]
}

@test "pkg_matches_version: Debian versions and revisions" {
    yes() { run sh_lib "pkg_matches_version deb '$1' '$2'"; assert_status 0; }
    no() { run sh_lib "pkg_matches_version deb '$1' '$2'"; assert_status 1; }
    yes 1.2.3 1.2.3
    yes 1.2.3-1 1.2.3
    yes 1.2.3-1ubuntu1 1.2.3
    yes 2:1.2.3-1 1.2.3
    no 1.2.30-1 1.2.3
    no 1.2.3.1 1.2.3
    no 1.2.3-rc1 1.2.3
    no 1.2.3-1-2 1.2.3
    no 1.2.2-1 1.2.3
}

@test "pkg_matches_version: RPM versions, any release, ~ for pre-releases" {
    yes() { run sh_lib "pkg_matches_version rpm '$1' '$2'"; assert_status 0; }
    no() { run sh_lib "pkg_matches_version rpm '$1' '$2'"; assert_status 1; }
    yes 1.2.3-1 1.2.3
    yes 1.2.3-4.fc44 1.2.3
    yes 1.2.3~rc.1-1 1.2.3-rc.1
    no 1.2.30-1 1.2.3
    no 1.2.3-1 1.2.4
}

@test "pool_prefix follows Debian's pool layout" {
    run sh_lib "pool_prefix hello"; [ "$output" = h ]
    run sh_lib "pool_prefix libfoo"; [ "$output" = libf ]
    run sh_lib "pool_prefix lib"; [ "$output" = l ]
    run sh_lib "pool_prefix 0ad"; [ "$output" = 0 ]
}

@test "pkg_meta refuses files that are not packages" {
    printf 'x' > "$TMP/a.txt"
    run sh_lib "pkg_meta '$TMP/a.txt'"
    assert_status 1
    assert_output_contains "neither a .deb nor an .rpm"
}
