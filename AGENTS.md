# Agent rules

| Rule | Enforced by | Command | Review finding |
| --- | --- | --- | --- |
| Do not leave dead code, and do not build a later slice's fragment upload in this client. A public function needs a caller in `lib/` (a test does not count). An unused private function or clause fails the compiler check. An in-VM `:httpc` fragment request is not that caller. | `Mix.Tasks.Selective.DeadCode` | `mix selective.dead_code` | Simplicity review of selective-elixir-exunit#1 at `32de4b1` (2026-10-22), findings 1, 6, and 11 |

OTP behaviour callbacks, `child_spec/1`, and `module_info`/`__info__` are the framework calling in, so they are not findings.

An exception is a trailing comment on the offending line, and the check rejects any other shape:

`# dead-code-allow: <reason> expires: YYYY-MM-DD approved: <name>`

not enforced: whether the reason is a good judgment. The marker format, the expiry date, and the approver token are enforced.
