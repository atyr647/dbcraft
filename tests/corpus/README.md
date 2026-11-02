# Golden corpus

Test-only scenarios replayed through framing, VarInt, packet decode and the protocol 777 state machine. Run with `make test` (or `bin/test_golden_corpus [--scenario=<id>] [--category=<cat>]`). The shipped server never reads this directory.

## Format (corpus_format 1)

Line-oriented `key: value`, ASCII. Blank lines and full-line `#` comments are ignored. The first line must be `corpus_format: 1`. Keys before the first `step:` line are scenario-level; after it they belong to that step.

Scenario keys: required `id`, `title`, `description`, `category`, `protocol` (777), `provenance` (hand-authored, captured, regression), `initial_state`; optional `final_state`, `reference` (required for regression).

Step keys: required `direction` (serverbound/clientbound), `input`, `outcome` (accepted/rejected/incomplete); accepted steps also require `packet_id`, `state_after`; optional `canonical` (true/false, accepted only), `rejection_category` (rejected/incomplete only).

`input` is hex (whitespace allowed), the complete frame including its length prefix; empty or odd-length input is malformed.

Categories: handshake, status, login, authentication, encryption, configuration, known_packs, registries, play, spawn, movement, block_interaction, inventory, commands, disconnect. States: HANDSHAKE, STATUS, LOGIN, CONFIGURATION, PLAY.

## Validation rules

Duplicate keys, missing required fields, bad enum values, zero steps, a rejected/incomplete step that is not last, duplicate IDs, files over 1 MiB and more than 1024 steps are errors. Any loader error fails the test run. Unknown keys are ignored. After a rejected or incomplete step the connection state must equal the state before it, and replay stops.

## Adding a case

Copy `_template.scenario` to `<id>.scenario`. IDs are unique, contain no whitespace, and should equal the file stem; never change an ID once shipped. Files starting with `_` are ignored by the loader; do not use this (or comments) to disable a case.

## Phase 1 inventory

handshake-valid-status, handshake-valid-login, handshake-invalid-intent, status-request, status-ping, status-in-handshake, wrong-direction, handshake-to-configuration, handshake-to-play, unknown-packet-id, truncated-frame, overlong-varint-length, framing-oversize-length, length-payload-mismatch, negative-length.

The status-ping case is included; nothing was omitted.
