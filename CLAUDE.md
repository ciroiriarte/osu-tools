# OSU Tools — OpenStack User Tools

## 1. Objectives
* Provide wrappers and new tools to simplify OpenStack usage via the openstack CLI and APIs

## 2. Technical Stack & Dependencies
* **Language:** Modern Bash

## 3. Coding Rules & Constraints
* Should use bash native capabilities as much as possible before falling back to external tools
* No magic strings, define variables with default values when required
* Coding style should be unified/standardized
* Options should always handle long and short alternatives.
* Help function must always exist.
* Every script must define a `SCRIPT_VERSION` variable near the top (after header comments, before configuration) and support `--version`/`-v` flags that output `<script-name> <version>`. The version must also appear in the `# Version:` header comment and in `--help` output.
* Execution of scripts that require parameters must present the user with a usage message when no parameter is provided.
* Output formatting should be clean & aesthetic, clear to the user.
* Use process bars to allow the user to understand process progress. Implement that only when formated output is not requested (CSV, JSON, etc)
* Use functions when scripts become long and complex.

## 4. Documentation
* Every script must have a corresponding man page under `man/man1/` in classic troff/groff format. The man page file uses section 1 (`.1` extension) and must document at minimum: NAME, SYNOPSIS, DESCRIPTION, OPTIONS, EXIT STATUS, EXAMPLES, AUTHORS, and SEE ALSO.
* Each script should have an entry in the README.md file
* Each entry should include name of the script, Author: Ciro Iriarte, Creation date, update date, Description, Requirements, Recommendations and usage example.
* Use UTF-8 based icons to make reading easier.
* Format should be consistent

## 5. Security
* Safe variable handling is required.
* Apply relevant safe coding practices you may know about.
