#!/usr/bin/env bash
# The pre-commit gate. Every invariant here is one the compiler cannot see and the test suite cannot
# fail on, so a grep is the only guard it has.
#
# Usage:
#   Scripts/verify.sh              run every check against this tree; exit 0 iff all pass
#   Scripts/verify.sh --self-test  prove every check still discriminates: each one is run against a
#                                  synthesized clean tree (must pass) and a tree with one planted
#                                  violation (must fail), outside the repository
#
# Two kinds of check, and each declares which kind it is:
#   - A prohibition greps for a forbidden construct. An empty match set is the passing state, so a
#     live run proves nothing about whether the grep still works; only --self-test does.
#   - A derivation builds a set from the tree and compares it to what the tree promises. An empty
#     derived set FAILS, because a derivation that finds nothing has lost its subject.
# A path carve-out first asserts that the thing it excuses exists, so the carve-out can neither
# outlive its subject nor quietly widen to a second file.

set -u

ROOT="${VERIFY_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
FAILURES=0

pass() { printf '[PASS] %s\n' "$1"; }
fail() { printf '[FAIL] %s\n' "$1"; FAILURES=$((FAILURES + 1)); }

# Lines of Swift source with comment-only lines removed, so a doc comment may name a banned
# construct while explaining why it is banned.
code_lines() {
  # $@: files
  grep -nHvE '^\s*//' "$@" 2>/dev/null
}

swift_files() {
  # $1: directory under ROOT
  find "$ROOT/$1" -name '*.swift' -type f 2>/dev/null | sort
}

# ---------------------------------------------------------------------------------------------------
# Checks. Each is a function that calls pass or fail exactly once.
# ---------------------------------------------------------------------------------------------------

# Prohibition. swift-format's NeverForceUnwrap and NeverUseForceTry cover `!` and `try!`; `as!` has no
# lint rule, so it is grepped here alongside `try!` for one place to read the rule.
check_force_ops() {
  local name="no try! or as! in Sources"
  local hits
  hits=$(code_lines $(swift_files Sources) | grep -E '\btry!|\bas!' || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition, with a derivation guarding its subject. HTTPCore imports Foundation only under the
# `#else` of a `#if canImport(FoundationEssentials)`, so the core stays portable. The derivation
# asserts at least one such conditional import exists; a core that imported nothing would otherwise
# pass a check about how it imports.
check_foundation_import() {
  local name="every import Foundation in Sources/HTTPCore sits under #else"
  local files hits guarded
  files=$(swift_files Sources/HTTPCore)
  guarded=$(grep -lE '^#if canImport\(FoundationEssentials\)' $files 2>/dev/null | wc -l | tr -d ' ')
  if [ "$guarded" -eq 0 ]; then
    fail "$name (no conditional FoundationEssentials import found; the check has lost its subject)"
    return
  fi
  # awk rather than grep -B1: a file whose first line is the import has no preceding line for -B1 to
  # show, and the filter would drop the hit.
  hits=$(awk 'FNR == 1 { prev = "" } /^import Foundation$/ && prev != "#else" { print FILENAME ":" FNR ": " $0 } { prev = $0 }' $files 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition. The core is portable and Combine-free; nothing in any target reaches for a UI
# framework, Combine, Observation, or Dispatch.
check_banned_imports() {
  local name="no banned import in Sources"
  local hits
  hits=$(grep -nHE '^\s*import (AppKit|Combine|Dispatch|Observation|SwiftUI|UIKit)\b' $(swift_files Sources) 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition. Time is injected; shared state is Synchronization's vocabulary.
check_wall_clock_and_locks() {
  local name="no wall clock, nanosecond sleep, DispatchQueue, NSLock, or OSAllocatedUnfairLock in Sources"
  local hits
  hits=$(code_lines $(swift_files Sources) | grep -E 'Date\(\)|Date\.now|Task\.sleep\(nanoseconds|DispatchQueue|NSLock|OSAllocatedUnfairLock' || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Derivation. The package carries exactly one `unsafe`, the InputStream read in StubURLProtocol, and
# HTTPCore carries none. The count is compared, not just the location, so a second one anywhere fails.
check_unsafe() {
  local name="exactly one unsafe in Sources, in HTTPTesting/StubURLProtocol.swift"
  local hits count
  hits=$(code_lines $(swift_files Sources) | grep -wE 'unsafe' || true)
  count=$(printf '%s' "$hits" | grep -c . || true)
  if [ "$count" -eq 1 ] && printf '%s' "$hits" | grep -q 'Sources/HTTPTesting/StubURLProtocol.swift:'; then
    pass "$name"
  else
    fail "$name (found $count)"; printf '%s\n' "$hits"
  fi
}

# Derivation. Every file in HTTPURLSession, and the two StubURLProtocol files in HTTPTesting, compile
# out on Linux behind `#if canImport(Darwin)`. The file set is derived from the tree and must be
# non-empty.
check_darwin_guard() {
  local name="every Darwin-only file is wrapped in #if canImport(Darwin)"
  local files missing
  files=$( (swift_files Sources/HTTPURLSession; find "$ROOT/Sources/HTTPTesting" -name 'StubURLProtocol*.swift' -type f 2>/dev/null) | sort)
  if [ -z "$files" ]; then fail "$name (no Darwin-only files found; the check has lost its subject)"; return; fi
  missing=$(grep -L '^#if canImport(Darwin)' $files || true)
  if [ -z "$missing" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$missing"; fi
}

# Derivation. Every file in HTTPPortable and in its test target compiles only when the `HTTPPortable`
# trait is enabled, behind `#if HTTPPortable`, so a build with the trait off fetches nothing and
# compiles nothing. The file set is derived from the tree and must be non-empty.
check_trait_guard() {
  local name="every HTTPPortable file is wrapped in #if HTTPPortable"
  local files missing
  files=$( (swift_files Sources/HTTPPortable; swift_files Tests/HTTPPortableTests) | sort)
  if [ -z "$files" ]; then fail "$name (no HTTPPortable files found; the check has lost its subject)"; return; fi
  missing=$(grep -L '^#if HTTPPortable' $files || true)
  if [ -z "$missing" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$missing"; fi
}

# Derivation. swift-log is fetched only when the `Logging` trait is enabled, so every file that
# imports it compiles only under `#if Logging`. The subject is derived from the import rather than
# from a directory, because these files live among the rest of HTTPCore and its suite; naming the
# trait in prose is not the trigger, since a file cannot use a `Logger` without importing it. Every
# spelling of the import counts, `@testable` and a submodule kind included, so that an unguarded file
# cannot hide behind one; `\b` keeps a package whose name merely starts with Logging out.
check_logging_trait_guard() {
  local name="every file that imports Logging is wrapped in #if Logging"
  local files missing
  files=$(grep -lE '^\s*(@testable )?import ([a-z]+ )?Logging\b' $(swift_files Sources) $(swift_files Tests) 2>/dev/null </dev/null | sort)
  if [ -z "$files" ]; then fail "$name (no file imports Logging; the check has lost its subject)"; return; fi
  missing=$(grep -L '^#if Logging' $files || true)
  if [ -z "$missing" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$missing"; fi
}

# Prohibition. Comments state constraints in domain terms; provenance belongs in commit messages.
check_coordinates() {
  local name="no plan, phase, task, or turn coordinates in Sources or Tests"
  local hits section
  section=$(printf '\302\247')
  hits=$(grep -nHE "\\bP[0-9]+-T[0-9]+\\b|\\bPh[a]se [0-9]|\\bT[a]sk [0-9]|\\bturn[- ][0-9]+\\b|$section" $(swift_files Sources) $(swift_files Tests) 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition. No em dashes anywhere user-facing.
check_em_dash() {
  local name="no em dash in Sources, Tests, Scripts, .github, Package.swift, README, CHANGELOG, CONTRIBUTING"
  local hits dash
  dash=$(printf '\342\200\224')
  hits=$(grep -rnH -- "$dash" "$ROOT/Sources" "$ROOT/Tests" "$ROOT/Scripts" "$ROOT/.github" "$ROOT/Package.swift" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/CONTRIBUTING.md" 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition. Testing vocabulary: name the type, never "double", "the driver", or "the seam". The
# em-dash check's scope minus Scripts and Package.swift, which carry no prose about tests.
check_test_jargon() {
  local name="no test double, driver, or seam jargon in Sources, Tests, .github, README, CHANGELOG, CONTRIBUTING"
  local hits
  hits=$(grep -rnHwiE "test doubles?|doubles|(the|a|second|no) double|the driver|the seam|a seam|seams" "$ROOT/Sources" "$ROOT/Tests" "$ROOT/.github" "$ROOT/README.md" "$ROOT/CHANGELOG.md" "$ROOT/CONTRIBUTING.md" 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition, with a derivation guarding its subject. Swift Testing only; the derivation asserts a
# test file imports Testing so an empty Tests tree cannot pass.
check_swift_testing_only() {
  local name="Swift Testing only in Tests"
  local files hits testing
  files=$(swift_files Tests)
  testing=$(grep -l '^import Testing$' $files 2>/dev/null | wc -l | tr -d ' ')
  if [ "$testing" -eq 0 ]; then fail "$name (no file imports Testing; the check has lost its subject)"; return; fi
  hits=$(grep -nHE 'import XCTest|XCTestCase|XCTAssert' $files 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Derivation. Every job in every workflow carries a job-level `timeout-minutes`, so a hang fails the
# job instead of sitting for GitHub's six-hour default. The job set is derived from the files and
# must be non-empty. A key is recognized only at the job's own indent: one nested inside a step
# bounds that step, not the job, and leaves the job unbounded. Any two-space key inside `jobs:`
# counts as a job, quoted spellings included, so an unrecognized name fails loudly rather than
# making its job invisible to the scan.
check_job_timeouts() {
  local name="every job in .github/workflows carries a timeout-minutes"
  local files report
  files=$(find "$ROOT/.github/workflows" \( -name '*.yml' -o -name '*.yaml' \) -type f 2>/dev/null | sort)
  if [ -z "$files" ]; then fail "$name (no workflow file found; the check has lost its subject)"; return; fi
  # `jobs:` is the only top-level block whose two-space keys are job names, so the scan tracks which
  # top-level block it is in rather than trusting the indent alone. The name is taken from the whole
  # line rather than the first field, so a quoted name carrying a space stays one name.
  report=$(awk '
    function close_job() {
      if (job != "") { total++; if (!has) print jobfile ": job " job " has no timeout-minutes" }
      job = ""; has = 0
    }
    FNR == 1 { close_job(); in_jobs = 0 }
    /^[^[:space:]#]/ { close_job(); in_jobs = ($0 ~ /^jobs:[[:space:]]*$/); next }
    in_jobs && /^  [^[:space:]#].*:[[:space:]]*$/ {
      close_job(); job = $0; sub(/^  /, "", job); sub(/:[[:space:]]*$/, "", job); jobfile = FILENAME; next
    }
    in_jobs && job != "" && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*(#.*)?$/ { has = 1; next }
    END { close_job(); if (total == 0) print "NO-JOBS" }
  ' $files 2>/dev/null || true)
  if [ "$report" = "NO-JOBS" ]; then
    fail "$name (no job found in any workflow; the check has lost its subject)"
  elif [ -z "$report" ]; then
    pass "$name"
  else
    fail "$name"; printf '%s\n' "$report"
  fi
}

# Derivation. Every suite under Tests carries the shared time limit, so a test that stops making
# progress fails its suite instead of holding the run open. The suite set is derived from the tree
# and must be non-empty. Four things the scan has to survive. The attribute is read across its whole
# argument list rather than one line, because swift-format wraps a long one onto a second line.
# String contents and any trailing comment are dropped before the constant is looked for, so neither
# a display name nor a comment can stand in for the trait. A suite counts wherever it is written:
# indented inside another suite, or behind another attribute on the same line, because a suite the
# scan failed to recognize would make this check go quiet instead of loud. And a test written at
# file scope belongs to an implicit suite that no attribute can reach, so it would run unbounded no
# matter what the suites carry; it is refused here rather than left to be discovered by a hang.
check_suite_time_limit() {
  local name="every suite in Tests carries the shared time limit"
  local files report
  files=$(swift_files Tests)
  if [ -z "$files" ]; then fail "$name (no test file found; the check has lost its subject)"; return; fi
  report=$(awk '
    # The line reduced to code: string contents dropped, and everything from a trailing comment on.
    # A comment is only a comment outside a string, so the two are tracked in one pass.
    function code(s,   i, c, out, instr, esc) {
      out = ""; instr = 0; esc = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (instr) {
          if (esc) esc = 0
          else if (c == "\\") esc = 1
          else if (c == "\"") instr = 0
          continue
        }
        if (c == "\"") { instr = 1; continue }
        if (c == "/" && substr(s, i + 1, 1) == "/") break
        out = out c
      }
      return out
    }
    function balance(s,   i, c, d) {
      d = 0
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if (c == "(") d++
        else if (c == ")") d--
      }
      return d
    }
    /^[[:space:]]*\/\// { next }
    /^(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*@Test([[:space:](]|$)/ {
      print FILENAME ":" FNR ": a test at file scope has no suite to bound it"
      next
    }
    /^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?[[:space:]]+)*@Suite([[:space:](]|$)/ {
      total++
      buf = code($0); loc = FILENAME ":" FNR; depth = balance(buf)
      while (depth > 0 && (getline) > 0) {
        chunk = code($0); buf = buf " " chunk; depth += balance(chunk)
      }
      if (index(buf, "suiteTimeLimitMinutes") == 0) print loc ": " buf
      next
    }
    END { if (total == 0) print "NO-SUITES" }
  ' $files 2>/dev/null || true)
  if [ "$report" = "NO-SUITES" ]; then
    fail "$name (no suite found in Tests; the check has lost its subject)"
  elif [ -z "$report" ]; then
    pass "$name"
  else
    fail "$name"; printf '%s\n' "$report"
  fi
}

# Prohibition. Local-only files are never force-added. Not self-tested: it reads the real index.
check_nothing_local_tracked() {
  local name="no local-only file is tracked"
  local hits
  hits=$(cd "$ROOT" && git ls-files -- CLAUDE.md AGENTS.md .claude plans '*_BULLETS.md' 2>/dev/null || true)
  if [ -z "$hits" ]; then pass "$name"; else fail "$name"; printf '%s\n' "$hits"; fi
}

# Prohibition. The format gate. An absent tool is a failure, never a skip. Not self-tested: it needs
# the toolchain and its rules are swift-format's to prove.
check_format() {
  local name="swift format lint --strict reports zero findings"
  if ! command -v swift >/dev/null 2>&1; then fail "$name (swift toolchain not found)"; return; fi
  if (cd "$ROOT" && swift format lint --strict --recursive Sources Tests >/dev/null 2>&1); then
    pass "$name"
  else
    fail "$name"
    (cd "$ROOT" && swift format lint --strict --recursive Sources Tests 2>&1 | head -40)
  fi
}

# The checks --self-test can plant a violation for, in run order.
SELF_TESTABLE=(
  check_force_ops
  check_foundation_import
  check_banned_imports
  check_wall_clock_and_locks
  check_unsafe
  check_darwin_guard
  check_trait_guard
  check_logging_trait_guard
  check_coordinates
  check_em_dash
  check_test_jargon
  check_swift_testing_only
  check_job_timeouts
  check_suite_time_limit
)

run_all() {
  for check in "${SELF_TESTABLE[@]}"; do "$check"; done
  check_nothing_local_tracked
  check_format
}

# ---------------------------------------------------------------------------------------------------
# Self-test. A clean synthesized tree that every check passes, then one planted violation per check.
# ---------------------------------------------------------------------------------------------------

write_clean_tree() {
  # $1: directory
  local d="$1"
  mkdir -p "$d/Sources/HTTPCore" "$d/Sources/HTTPPortable" "$d/Sources/HTTPURLSession" "$d/Sources/HTTPTesting" "$d/Tests/HTTPCoreTests" "$d/Tests/HTTPPortableTests" "$d/Scripts"
  cat > "$d/Sources/HTTPCore/Request.swift" <<'EOF'
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// A request. The doc comment may say Date() and unsafe; code lines may not.
public struct Request: Sendable {
  public let body: Data?
}
EOF
  cat > "$d/Sources/HTTPCore/LoggingObserver.swift" <<'EOF'
#if Logging
import Logging

public struct LoggingObserver: Sendable {}
#endif
EOF
  cat > "$d/Sources/HTTPURLSession/URLSessionTransport.swift" <<'EOF'
#if canImport(Darwin)
import Foundation
import HTTPCore

public struct URLSessionTransport: Sendable {}
#endif
EOF
  cat > "$d/Sources/HTTPPortable/AsyncHTTPClientTransport.swift" <<'EOF'
#if HTTPPortable
import HTTPCore

public struct AsyncHTTPClientTransport: Sendable {}
#endif
EOF
  # The suite here is written in the wrapped shape swift-format produces for a long attribute, so
  # the clean-tree arm fails if the scan stops reading at the end of the first line.
  cat > "$d/Tests/HTTPPortableTests/AsyncHTTPClientTransportTests.swift" <<'EOF'
#if HTTPPortable
import HTTPTesting
import Testing

@Suite(
  "the AsyncHTTPClient transport", .timeLimit(.minutes(suiteTimeLimitMinutes)))
struct AsyncHTTPClientTransportTests {
  @Test func aRequestReachesTheServer() {
    #expect(true)
  }
}
#endif
EOF
  cat > "$d/Sources/HTTPTesting/StubURLProtocol.swift" <<'EOF'
#if canImport(Darwin)
import Foundation

final class StubURLProtocol: URLProtocol {
  func read(_ stream: InputStream, into buffer: inout [UInt8]) -> Int {
    unsafe stream.read(&buffer, maxLength: buffer.count)
  }
}
#endif
EOF
  cat > "$d/Sources/HTTPTesting/MockTransport.swift" <<'EOF'
import HTTPCore
import Synchronization

public final class MockTransport: Sendable {}
EOF
  cat > "$d/Tests/HTTPCoreTests/RequestTests.swift" <<'EOF'
import HTTPCore
import HTTPTesting
import Testing

@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct RequestTests {
  @Test func aRequestCarriesItsBody() {
    #expect(true)
  }
}
EOF
  mkdir -p "$d/.github/workflows"
  cat > "$d/.github/workflows/ci.yml" <<'EOF'
name: CI

on:
  push:
    branches: [main]
  pull_request:

jobs:
  linux:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7

  lint:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    steps:
      - uses: actions/checkout@v7
EOF
  cat > "$d/.github/workflows/docs.yml" <<'EOF'
name: Docs

on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  build:
    runs-on: macos-26
    timeout-minutes: 15
    steps:
      - uses: actions/checkout@v7
EOF
  printf '# Readme\n' > "$d/README.md"
  printf '# Changelog\n' > "$d/CHANGELOG.md"
  printf '# Contributing\n' > "$d/CONTRIBUTING.md"
  printf '// swift-tools-version: 6.2\n' > "$d/Package.swift"
}

# Runs one check against $1 and echoes its outcome as PASS or FAIL, swallowing output.
outcome_of() {
  # $1: directory, $2: check function
  local saved="$FAILURES" result
  FAILURES=0
  ROOT="$1" "$2" >/dev/null 2>&1
  if [ "$FAILURES" -eq 0 ]; then result=PASS; else result=FAIL; fi
  FAILURES="$saved"
  printf '%s' "$result"
}

# One negative per check: the smallest edit that must trip it.
plant_violation() {
  # $1: directory, $2: check function
  local d="$1"
  case "$2" in
    check_force_ops)
      printf 'let x = y as! Int\n' >> "$d/Sources/HTTPCore/Request.swift" ;;
    check_foundation_import)
      printf 'import Foundation\n' > "$d/Sources/HTTPCore/Unguarded.swift" ;;
    check_banned_imports)
      printf 'import Combine\n' >> "$d/Sources/HTTPCore/Request.swift" ;;
    check_wall_clock_and_locks)
      printf 'let now = Date()\n' >> "$d/Sources/HTTPCore/Request.swift" ;;
    check_unsafe)
      printf 'let n = unsafe ptr.load()\n' >> "$d/Sources/HTTPCore/Request.swift" ;;
    check_darwin_guard)
      printf 'import Foundation\npublic struct Extra {}\n' > "$d/Sources/HTTPURLSession/Extra.swift" ;;
    check_trait_guard)
      printf 'import Testing\n' > "$d/Tests/HTTPPortableTests/Unguarded.swift" ;;
    check_logging_trait_guard)
      printf 'import Logging\n' > "$d/Sources/HTTPCore/Unguarded.swift" ;;
    check_coordinates)
      printf '// Added in P3\055T2 for Ph\141se 4\n' >> "$d/Sources/HTTPCore/Request.swift" ;;
    check_em_dash)
      printf 'A line \342\200\224 with an em dash\n' >> "$d/README.md" ;;
    check_test_jargon)
      printf 'Swap in a test double here.\n' >> "$d/README.md" ;;
    check_swift_testing_only)
      printf 'import XCTest\n' >> "$d/Tests/HTTPCoreTests/RequestTests.swift" ;;
    check_job_timeouts)
      printf 'name: Extra\n\non:\n  push:\n\njobs:\n  stray:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v7\n' > "$d/.github/workflows/extra.yml" ;;
    check_suite_time_limit)
      printf 'import Testing\n\n@Suite struct UnboundedTests {\n  @Test func aTestRuns() {\n    #expect(true)\n  }\n}\n' > "$d/Tests/HTTPCoreTests/UnboundedTests.swift" ;;
  esac
}

# A further negative for a check whose subject has more than one shape to recognize: one violation in
# the second shape, which must also fail.
plant_second_violation() {
  # $1: directory, $2: check function; returns 1 when the check has one shape only
  local d="$1"
  case "$2" in
    check_logging_trait_guard)
      printf '@testable import Logging\n' > "$d/Tests/HTTPCoreTests/Unguarded.swift" ;;
    # A key indented into a step bounds that step, not the job, so the job is still unbounded.
    check_job_timeouts)
      printf 'name: Nested\n\non:\n  push:\n\njobs:\n  nested:\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v7\n        timeout-minutes: 5\n' > "$d/.github/workflows/nested.yml" ;;
    # A suite nested inside a bounded one is indented, so a scan anchored at the margin would not
    # see it. The outer suite carries the limit; the inner one does not.
    check_suite_time_limit)
      printf 'import HTTPTesting\nimport Testing\n\n@Suite(.timeLimit(.minutes(suiteTimeLimitMinutes))) struct OuterTests {\n  @Suite struct NestedTests {\n    @Test func aTestRuns() {\n      #expect(true)\n    }\n  }\n}\n' > "$d/Tests/HTTPCoreTests/NestedTests.swift" ;;
    *) return 1 ;;
  esac
}

# A third negative for a check whose subject has a third shape to recognize, which must also fail.
plant_third_violation() {
  # $1: directory, $2: check function; returns 1 when the check has fewer than three shapes
  local d="$1"
  case "$2" in
    # A quoted job name is still a job. Failing to recognize it would hide the job rather than
    # report it, which is the one way this check can go quiet instead of loud.
    check_job_timeouts)
      printf 'name: Quoted\n\non:\n  push:\n\njobs:\n  "quoted":\n    runs-on: ubuntu-latest\n    steps:\n      - uses: actions/checkout@v7\n' > "$d/.github/workflows/quoted.yml" ;;
    # A suite is still a suite when another attribute precedes it on the line.
    check_suite_time_limit)
      printf 'import Testing\n\n@MainActor @Suite struct PrefixedTests {\n  @Test func aTestRuns() {\n    #expect(true)\n  }\n}\n' > "$d/Tests/HTTPCoreTests/PrefixedTests.swift" ;;
    *) return 1 ;;
  esac
}

# A fourth negative, for a check whose subject has a fourth shape to recognize.
plant_fourth_violation() {
  # $1: directory, $2: check function; returns 1 when the check has fewer than four shapes
  local d="$1"
  case "$2" in
    # Naming the constant in a comment is not carrying the trait.
    check_suite_time_limit)
      printf 'import Testing\n\n@Suite struct CommentedTests {  // suiteTimeLimitMinutes\n  @Test func aTestRuns() {\n    #expect(true)\n  }\n}\n' > "$d/Tests/HTTPCoreTests/CommentedTests.swift" ;;
    *) return 1 ;;
  esac
}

# A fifth negative, for a check whose subject has a fifth shape to recognize.
plant_fifth_violation() {
  # $1: directory, $2: check function; returns 1 when the check has fewer than five shapes
  local d="$1"
  case "$2" in
    # A test at file scope is in an implicit suite no attribute reaches, so no suite bounds it.
    check_suite_time_limit)
      printf 'import Testing\n\n@Test func aTestAtFileScopeRuns() {\n  #expect(true)\n}\n' > "$d/Tests/HTTPCoreTests/FileScopeTests.swift" ;;
    *) return 1 ;;
  esac
}

# A second negative for each derivation: remove its subject, which must also fail.
remove_subject() {
  # $1: directory, $2: check function; returns 1 when the check has no subject to remove
  local d="$1"
  case "$2" in
    check_foundation_import)
      printf 'public struct Request {}\n' > "$d/Sources/HTTPCore/Request.swift" ;;
    check_unsafe)
      printf 'import Foundation\n' > "$d/Sources/HTTPTesting/StubURLProtocol.swift" ;;
    check_darwin_guard)
      rm -rf "$d/Sources/HTTPURLSession"; rm -f "$d/Sources/HTTPTesting/StubURLProtocol.swift" ;;
    check_trait_guard)
      rm -rf "$d/Sources/HTTPPortable" "$d/Tests/HTTPPortableTests" ;;
    check_logging_trait_guard)
      rm -f "$d/Sources/HTTPCore/LoggingObserver.swift" ;;
    check_swift_testing_only)
      printf 'import HTTPCore\n' > "$d/Tests/HTTPCoreTests/RequestTests.swift"
      printf '#if HTTPPortable\nimport HTTPCore\n#endif\n' > "$d/Tests/HTTPPortableTests/AsyncHTTPClientTransportTests.swift" ;;
    check_job_timeouts)
      rm -rf "$d/.github" ;;
    # The tree keeps its test files and loses every suite, so the arm proves the empty derived set
    # fails on its own rather than on a file-scope test the check also refuses.
    check_suite_time_limit)
      printf 'import HTTPCore\nimport Testing\n\nstruct NotASuite {}\n' > "$d/Tests/HTTPCoreTests/RequestTests.swift"
      printf '#if HTTPPortable\nimport Testing\n\nstruct NotASuite {}\n#endif\n' > "$d/Tests/HTTPPortableTests/AsyncHTTPClientTransportTests.swift" ;;
    *) return 1 ;;
  esac
}

self_test() {
  local scratch clean planted got arms=0
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/verify-self-test.XXXXXX")
  # Expanded now: the trap runs after this function's locals are gone.
  trap "rm -rf '$scratch'" EXIT

  clean="$scratch/clean"
  write_clean_tree "$clean"
  for check in "${SELF_TESTABLE[@]}"; do
    got=$(outcome_of "$clean" "$check")
    arms=$((arms + 1))
    if [ "$got" = PASS ]; then pass "self-test: $check passes a clean tree"; else fail "self-test: $check FAILED a clean tree"; fi
  done

  for check in "${SELF_TESTABLE[@]}"; do
    planted="$scratch/planted-$check"
    write_clean_tree "$planted"
    plant_violation "$planted" "$check"
    got=$(outcome_of "$planted" "$check")
    arms=$((arms + 1))
    if [ "$got" = FAIL ]; then pass "self-test: $check trips on its planted violation"; else fail "self-test: $check MISSED its planted violation"; fi

    planted="$scratch/second-$check"
    write_clean_tree "$planted"
    if plant_second_violation "$planted" "$check"; then
      got=$(outcome_of "$planted" "$check")
      arms=$((arms + 1))
      if [ "$got" = FAIL ]; then pass "self-test: $check trips on its second planted violation"; else fail "self-test: $check MISSED its second planted violation"; fi
    fi

    planted="$scratch/third-$check"
    write_clean_tree "$planted"
    if plant_third_violation "$planted" "$check"; then
      got=$(outcome_of "$planted" "$check")
      arms=$((arms + 1))
      if [ "$got" = FAIL ]; then pass "self-test: $check trips on its third planted violation"; else fail "self-test: $check MISSED its third planted violation"; fi
    fi

    planted="$scratch/fourth-$check"
    write_clean_tree "$planted"
    if plant_fourth_violation "$planted" "$check"; then
      got=$(outcome_of "$planted" "$check")
      arms=$((arms + 1))
      if [ "$got" = FAIL ]; then pass "self-test: $check trips on its fourth planted violation"; else fail "self-test: $check MISSED its fourth planted violation"; fi
    fi

    planted="$scratch/fifth-$check"
    write_clean_tree "$planted"
    if plant_fifth_violation "$planted" "$check"; then
      got=$(outcome_of "$planted" "$check")
      arms=$((arms + 1))
      if [ "$got" = FAIL ]; then pass "self-test: $check trips on its fifth planted violation"; else fail "self-test: $check MISSED its fifth planted violation"; fi
    fi

    planted="$scratch/subjectless-$check"
    write_clean_tree "$planted"
    if remove_subject "$planted" "$check"; then
      got=$(outcome_of "$planted" "$check")
      arms=$((arms + 1))
      if [ "$got" = FAIL ]; then pass "self-test: $check fails when its subject is gone"; else fail "self-test: $check PASSED with its subject gone"; fi
    fi
  done
  printf '%d self-test arms\n' "$arms"
}

# ---------------------------------------------------------------------------------------------------

case "${1:-}" in
  "") run_all ;;
  --self-test) self_test ;;
  *) printf 'usage: %s [--self-test]\n' "$0" >&2; exit 2 ;;
esac

if [ "$FAILURES" -eq 0 ]; then exit 0; fi
printf '%d check(s) failed\n' "$FAILURES"
exit 1
