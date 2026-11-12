#!/usr/bin/env python3
"""Deterministic PreToolUse security guard for Antigravity Sandbox.

Enforces:
- No remote Git pushes or plumbing push commands.
- No Git remote mutations.
- No tampering with .git metadata/hooks/config or execution-hijacking Git config keys.
- No Git environment variable overrides or BypassSandbox escalation requests.
"""

from __future__ import annotations

import json
import os
import posixpath
import re
import shlex
import sys
from typing import Any

FORBIDDEN_GIT_SUBCOMMANDS: frozenset[str] = frozenset(
    {"push", "send-pack", "http-push", "receive-pack", "daemon", "worktree", "hook"}
)

READONLY_GIT_WRITE_SUBCOMMANDS: frozenset[str] = frozenset(
    {
        "add",
        "stage",
        "commit",
        "pull",
        "fetch",
        "merge",
        "rebase",
        "cherry-pick",
        "revert",
        "reset",
        "checkout",
        "switch",
        "restore",
        "stash",
        "clean",
        "rm",
        "mv",
        "am",
        "apply",
        "gc",
        "prune",
    }
)

READONLY_BRANCH_TAG_FLAGS: frozenset[str] = frozenset(
    {
        "-l",
        "--list",
        "-a",
        "--all",
        "-r",
        "--remotes",
        "-v",
        "-vv",
        "--verbose",
        "--show-current",
        "--contains",
        "--merged",
        "--no-merged",
        "--points-at",
    }
)

FORBIDDEN_REMOTE_ACTIONS: frozenset[str] = frozenset(
    {
        "add",
        "set-url",
        "rename",
        "remove",
        "rm",
        "prune",
        "update",
        "set-head",
        "set-branches",
    }
)

FORBIDDEN_GIT_OPTS: frozenset[str] = frozenset(
    {
        "--exec-path",
        "--work-tree",
        "--git-dir",
        "--upload-pack",
        "--receive-pack",
        "--template",
        "--separate-git-dir",
        "--config-env",
    }
)

GIT_OPTS_WITH_VALUE: frozenset[str] = frozenset({"-C", "-c", "--namespace"})

DANGEROUS_GIT_CONFIG_PATTERN: re.Pattern[str] = re.compile(
    r"^(core\.(fsmonitor|sshcommand|hookspath|pager|editor|gitproxy|askpass|"
    r"worktree|attributesfile|excludesfile|alternaterefscommand)|"
    r"extensions\.|remote\.|url\.|protocol\.|credential\.|filter\.|alias\.|uploadpack\.|receivepack\.|"
    r"include\.|includeif\.|diff\.|merge\.|difftool\.|mergetool\.|sequence\.|interactive\.|"
    r"browser\.|man\.|guitool\.|pager\.|http\.proxy|https\.proxy)",
    re.IGNORECASE,
)

FORBIDDEN_ENV_VARS_PATTERN: re.Pattern[str] = re.compile(
    r"\b(GIT_SSH_COMMAND|GIT_SSH|GIT_EXEC_PATH|GIT_TEMPLATE_DIR|"
    r"GIT_CONFIG|GIT_CONFIG_GLOBAL|GIT_CONFIG_SYSTEM|GIT_CONFIG_PARAMETERS|GIT_CONFIG_COUNT|"
    r"GIT_DIR|GIT_WORK_TREE|GIT_COMMON_DIR|GIT_INDEX_FILE|"
    r"GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|"
    r"GIT_EXTERNAL_DIFF|GIT_ASKPASS|SSH_ASKPASS|GIT_PAGER|GIT_EDITOR|GIT_SEQUENCE_EDITOR|"
    r"XDG_CONFIG_HOME|LD_PRELOAD|DYLD_INSERT_LIBRARIES)\s*=",
    re.IGNORECASE,
)

READONLY_GIT_CONFIG_FLAGS: frozenset[str] = frozenset(
    {"--get", "--get-all", "--get-regexp", "--list", "-l"}
)

WRITE_TOOL_NAMES: frozenset[str] = frozenset(
    {
        "write_file",
        "edit_file",
        "create_file",
        "write_to_file",
        "replace_file_content",
        "multi_replace_file_content",
        "append_file",
        "patch_file",
        "apply_patch",
        "apply_diff",
        "save_file",
        "delete_file",
        "remove_file",
        "move_file",
        "rename_file",
        "copy_file",
        "notebook_edit",
        "str_replace_editor",
        "insert_edit_into_file",
        "create_new_file",
    }
)

PATH_ARG_KEYS: frozenset[str] = frozenset(
    {
        "path",
        "targetfile",
        "target_file",
        "targetpath",
        "target_path",
        "absolutepath",
        "absolute_path",
        "filepath",
        "file_path",
        "filename",
        "file_name",
        "file",
        "destination",
        "dest",
        "destpath",
        "dest_path",
        "newpath",
        "new_path",
        "oldpath",
        "old_path",
        "source",
        "src",
        "directory",
        "dir",
    }
)

FORBIDDEN_CUSTOMIZATION_DIRS: frozenset[str] = frozenset(
    {".agents", ".agent", "_agents", "_agent"}
)

FORBIDDEN_CUSTOMIZATION_FILES: frozenset[str] = frozenset(
    {"hooks.json", "mcp_config.json", "config.worktree", ".continuerules"}
)

FORBIDDEN_CICD_AND_META_DIRS: frozenset[str] = frozenset(
    {".github", ".circleci", ".buildkite", ".husky"}
)

FORBIDDEN_CICD_AND_META_FILES: frozenset[str] = frozenset(
    {
        ".gitlab-ci.yml",
        ".gitlab-ci.yaml",
        "jenkinsfile",
        "azure-pipelines.yml",
        ".travis.yml",
        "cloudbuild.yaml",
        "bitbucket-pipelines.yml",
        ".gitattributes",
        ".gitmodules",
        ".pre-commit-config.yaml",
        ".envrc",
        ".mise.toml",
    }
)

SAFE_ENV_TEMPLATES: frozenset[str] = frozenset(
    {".env.example", ".env.sample", ".env.template", ".env.dist"}
)

FORBIDDEN_IDE_EXEC_FILES: dict[str, frozenset[str]] = {
    ".vscode": frozenset({"tasks.json", "launch.json", "settings.json", "extensions.json"}),
    ".idea": frozenset({"tasks.xml", "workspace.xml"}),
}

SHELL_INTERPRETERS: frozenset[str] = frozenset(
    {"sh", "bash", "zsh", "dash", "ksh", "ash", "csh", "tcsh"}
)

TRANSPARENT_CMD_WRAPPERS: frozenset[str] = frozenset(
    {"env", "command", "builtin", "exec", "nohup", "time", "nice", "setsid"}
)

STANDALONE_DOT_GIT_PATTERN: re.Pattern[str] = re.compile(
    r"(?:^|[^a-zA-Z0-9_-])\.git(?:$|[^a-zA-Z0-9_])",
    re.IGNORECASE,
)


def _extract_workspaces_repo(path_str: str) -> tuple[str, str, list[str]] | None:
    norm = posixpath.normpath(path_str.replace("\\", "/"))
    parts = [p for p in norm.split("/") if p and p != "."]
    for i, part in enumerate(parts):
        if part == "workspaces" and i + 1 < len(parts):
            prefix = "/" + "/".join(parts[: i + 1]) if norm.startswith("/") else "/".join(parts[: i + 1])
            repo_name = parts[i + 1]
            subparts = parts[i + 2 :]
            return prefix, repo_name, subparts
    return None


def _decode_shell_escapes(s: str) -> str:
    s_hex = re.sub(
        r"\\x([0-9a-fA-F]{2})",
        lambda m: chr(int(m.group(1), 16)),
        s,
    )
    return re.sub(
        r"\\0?([0-7]{3})",
        lambda m: chr(int(m.group(1), 8)) if int(m.group(1), 8) < 128 else m.group(0),
        s_hex,
    )


def _is_git_metadata_path(parts_lower: set[str]) -> bool:
    return ".git" in parts_lower


def _is_git_config_file_path(parts_lower: set[str]) -> bool:
    return ".gitconfig" in parts_lower or (
        ".config" in parts_lower and "git" in parts_lower
    )


ANTIGRAVITY_BRAIN_ROOT = "/home/agent/.gemini/antigravity/brain"


def _is_antigravity_brain_path(abs_path: str, real_path: str) -> bool:
    """Return True if both abs_path and real_path resolve inside the artifacts brain directory."""
    abs_norm = abs_path.replace("\\", "/").rstrip("/")
    real_norm = real_path.replace("\\", "/").rstrip("/")
    brain_real = os.path.realpath(ANTIGRAVITY_BRAIN_ROOT).replace("\\", "/").rstrip("/")
    return (
        abs_norm.startswith(ANTIGRAVITY_BRAIN_ROOT + "/")
        and real_norm.startswith(brain_real + "/")
    )


def _is_sandbox_configuration_path(
    parts_lower: set[str], normalized_path: str, real_path: str
) -> bool:
    if _is_antigravity_brain_path(normalized_path, real_path):
        return False
    return (
        ".gemini" in parts_lower
        or normalized_path.startswith("/home/agent/.gemini")
        or real_path.startswith("/home/agent/.gemini")
    )


def _is_code_server_state_path(parts_lower: set[str]) -> bool:
    return (
        "code-server" in parts_lower
        and (".local" in parts_lower or "state" in parts_lower)
    ) or ".continue" in parts_lower


def _is_customization_directory_or_file(
    parts_lower: set[str], norm_parts: list[str], real_parts: list[str]
) -> bool:
    return bool(parts_lower & FORBIDDEN_CUSTOMIZATION_DIRS) or (
        bool(norm_parts) and norm_parts[-1].lower() in FORBIDDEN_CUSTOMIZATION_FILES
    ) or (
        bool(real_parts) and real_parts[-1].lower() in FORBIDDEN_CUSTOMIZATION_FILES
    )


def _is_cicd_or_repo_meta_path(
    parts_lower: set[str], norm_parts: list[str], real_parts: list[str]
) -> bool:
    return bool(parts_lower & FORBIDDEN_CICD_AND_META_DIRS) or (
        bool(norm_parts) and norm_parts[-1].lower() in FORBIDDEN_CICD_AND_META_FILES
    ) or (
        bool(real_parts) and real_parts[-1].lower() in FORBIDDEN_CICD_AND_META_FILES
    )


def _is_secret_env_filename(leaf: str) -> bool:
    return leaf == ".env" or (leaf.startswith(".env.") and leaf not in SAFE_ENV_TEMPLATES)


def _is_ide_execution_config_file(parent_dir: str, leaf: str) -> bool:
    return parent_dir in FORBIDDEN_IDE_EXEC_FILES and leaf in FORBIDDEN_IDE_EXEC_FILES[parent_dir]


def _check_sensitive_leaf_and_parent(parts_seq: list[str], path_value: str) -> str | None:
    if not parts_seq:
        return None
    leaf = parts_seq[-1].lower()
    if _is_secret_env_filename(leaf):
        return f"Accessing or modifying masked secret file '{path_value}' is forbidden."
    if len(parts_seq) >= 2:
        parent_dir = parts_seq[-2].lower()
        if _is_ide_execution_config_file(parent_dir, leaf):
            return f"Modifying IDE host-execution configuration '{path_value}' is forbidden."
    return None


def _check_cross_repo_boundaries(
    abs_path: str,
    real_path: str,
    ws_root_real: str,
    repo_real: str,
    path_value: str,
    allowed_workspaces: list[str] | None,
) -> str | None:
    effective_workspaces: list[str] = []
    if allowed_workspaces:
        effective_workspaces.extend(
            w for w in allowed_workspaces if isinstance(w, str) and w.strip()
        )
    env_ws = os.environ.get("AGY_WORKSPACE", "").strip()
    if env_ws:
        effective_workspaces.append(env_ws)

    if effective_workspaces:
        for ws in effective_workspaces:
            ws_norm = posixpath.normpath(os.path.abspath(ws).replace("\\", "/")).rstrip("/")
            ws_real = os.path.realpath(os.path.abspath(ws)).replace("\\", "/").rstrip("/")
            if (
                abs_path.replace("\\", "/").startswith(ws_norm + "/")
                and real_path.startswith(ws_real + "/")
            ):
                return None
        return f"Cross-repository write to '{path_value}' outside active workspace is forbidden."

    cwd_real = os.path.realpath(os.getcwd()).replace("\\", "/")
    cwd_ws_info = _extract_workspaces_repo(cwd_real)
    if not cwd_ws_info:
        return None

    cwd_ws_root, cwd_repo, _ = cwd_ws_info
    target_repo_dir = os.path.join(ws_root_real, repo_real)
    if (
        cwd_ws_root == ws_root_real
        and repo_real != cwd_repo
        and os.path.exists(target_repo_dir)
    ):
        return (
            f"Cross-repository write from '{cwd_repo}' to '{repo_real}' "
            f"('{path_value}') is forbidden."
        )

    return None


def _check_file_path(
    path_value: str,
    allowed_workspaces: list[str] | None = None,
) -> str | None:
    if any(ord(c) < 32 for c in path_value):
        return "Control characters or null bytes in file path are forbidden."
    raw = path_value.strip().replace("\\", "/")
    if not raw:
        return "Empty file path is forbidden."

    raw_parts = [p for p in raw.split("/") if p and p != "."]
    normalized = posixpath.normpath(raw)
    norm_parts = [p for p in normalized.split("/") if p and p != "."]
    abs_path = os.path.abspath(raw)
    real_path = os.path.realpath(abs_path).replace("\\", "/")
    real_parts = [p for p in real_path.split("/") if p and p != "."]

    all_parts_lower = {p.lower() for p in (*raw_parts, *norm_parts, *real_parts)}

    if "mnt" in all_parts_lower and ("lower" in all_parts_lower or "overlays" in all_parts_lower):
        return f"Direct access to internal overlay mount directories ('{path_value}') is forbidden."

    if _is_git_metadata_path(all_parts_lower):
        return f"File access to '{path_value}' (.git metadata/hooks) is forbidden."

    if _is_git_config_file_path(all_parts_lower):
        return f"Modifying Git configuration file '{path_value}' is forbidden."

    abs_path_norm = abs_path.replace("\\", "/")
    if _is_sandbox_configuration_path(all_parts_lower, abs_path_norm, real_path):
        return "Modifying sandbox configuration, skills, or hooks is forbidden."

    if _is_code_server_state_path(all_parts_lower):
        return "Modifying persisted code-server IDE state or extensions is forbidden."

    if _is_customization_directory_or_file(all_parts_lower, norm_parts, real_parts):
        return f"Modifying agent customization or hook configuration '{path_value}' is forbidden."

    if _is_cicd_or_repo_meta_path(all_parts_lower, norm_parts, real_parts):
        return f"Modifying protected CI/CD or repository metadata path '{path_value}' is forbidden."

    for parts_seq in (raw_parts, norm_parts, real_parts):
        sensitive_denial = _check_sensitive_leaf_and_parent(parts_seq, path_value)
        if sensitive_denial:
            return sensitive_denial

    if ".." in raw_parts or ".." in norm_parts:
        return f"Path traversal ('..') in file path '{path_value}' is forbidden."

    if _is_antigravity_brain_path(abs_path_norm, real_path):
        rel = abs_path_norm[len(ANTIGRAVITY_BRAIN_ROOT) :].lstrip("/")
        probe = ANTIGRAVITY_BRAIN_ROOT
        for part in rel.split("/"):
            probe = os.path.join(probe, part)
            if os.path.islink(probe):
                return f"Writing through symlink '{probe}' is forbidden."
        return None

    ws_info_norm = _extract_workspaces_repo(abs_path)
    ws_info_real = _extract_workspaces_repo(real_path)
    if not ws_info_norm or not ws_info_real:
        return f"Writing outside workspace repositories ('{path_value}') is forbidden."

    ws_root_norm, repo_norm, subparts_norm = ws_info_norm
    ws_root_real, repo_real, subparts_real = ws_info_real
    if not subparts_norm or not subparts_real:
        return f"Writing directly to workspace root ('{path_value}') outside a repository file is forbidden."

    expected_repo_real = os.path.realpath(os.path.join(ws_root_norm, repo_norm)).replace("\\", "/")
    if not real_path.startswith(expected_repo_real.rstrip("/") + "/"):
        return f"Symlink traversal outside repository root ('{path_value}' -> '{real_path}') is forbidden."

    probe = os.path.join(ws_root_norm, repo_norm)
    for part in subparts_norm:
        probe = os.path.join(probe, part)
        if os.path.islink(probe):
            return f"Writing through symlink '{probe}' is forbidden."

    return _check_cross_repo_boundaries(
        abs_path, real_path, ws_root_real, repo_real, path_value, allowed_workspaces
    )


def _has_forbidden_git_option(arg_lower: str) -> bool:
    return arg_lower in FORBIDDEN_GIT_OPTS or any(
        arg_lower.startswith(f"{opt}=") for opt in FORBIDDEN_GIT_OPTS
    )


def _is_mutating_branch_or_tag(sub_lower: str, rest: list[str]) -> bool:
    if not rest:
        return False
    for arg in rest:
        arg_lower = arg.lower()
        if arg_lower in ("-d", "--delete", "-m", "--move", "-c", "--copy", "-f", "--force", "--annotate", "-s", "--sign", "-u", "--unset-upstream") or arg_lower.startswith("--set-upstream-to="):
            return True
        if sub_lower == "tag" and arg == "-a":
            return True
        if arg_lower in READONLY_BRANCH_TAG_FLAGS or arg_lower.startswith(("--sort=", "--format=", "--color", "--no-color", "--column", "--no-column", "--abbrev", "--no-abbrev")):
            return False
        if not arg.startswith("-"):
            return True
    return False


def _inspect_git_config_arguments(rest: list[str]) -> str | None:
    if any(flag in READONLY_GIT_CONFIG_FLAGS for flag in rest):
        return None
    for arg in rest:
        arg_lower = arg.lower()
        if arg.startswith("-"):
            if arg_lower in ("--file", "-f", "--blob", "--global", "--system", "--worktree") or any(
                arg_lower.startswith(f"{opt}=") for opt in ("--file", "--blob")
            ):
                return f"Writing to non-local or arbitrary git config via '{arg}' is forbidden."
            continue
        if DANGEROUS_GIT_CONFIG_PATTERN.search(arg):
            return f"Modifying security-sensitive Git config key '{arg}' is forbidden."
    return (
        "Git write operation 'git config' is disabled inside the sandbox (.git is mounted read-only). "
        "Run Git write operations from your host terminal."
    )


def _inspect_git_tokens(tokens: list[str]) -> str | None:
    idx = 1
    subcommand: str | None = None
    subcommand_idx = -1

    while idx < len(tokens):
        tok = tokens[idx]
        if tok == "--":
            idx += 1
            if idx < len(tokens):
                subcommand = tokens[idx]
                subcommand_idx = idx
            break

        tok_lower = tok.lower()

        if _has_forbidden_git_option(tok_lower):
            return f"Using dangerous Git option '{tok}' is forbidden inside the sandbox."

        if tok == "-c" and idx + 1 < len(tokens):
            cfg_expr = tokens[idx + 1]
            cfg_key = cfg_expr.split("=", 1)[0].strip()
            if DANGEROUS_GIT_CONFIG_PATTERN.search(cfg_key):
                return f"Overriding execution-sensitive Git config '{cfg_key}' via -c is forbidden."
            idx += 2
            continue
        if tok.startswith("-c") and len(tok) > 2:
            cfg_key = tok[2:].split("=", 1)[0].strip()
            if DANGEROUS_GIT_CONFIG_PATTERN.search(cfg_key):
                return f"Overriding execution-sensitive Git config '{cfg_key}' via -c is forbidden."
            idx += 1
            continue

        if tok in GIT_OPTS_WITH_VALUE:
            idx += 2
            continue
        if any(tok.startswith(f"{opt}=") for opt in GIT_OPTS_WITH_VALUE):
            idx += 1
            continue
        if tok.startswith("-"):
            idx += 1
            continue

        subcommand = tok
        subcommand_idx = idx
        break

    if not subcommand:
        return None

    sub_lower = subcommand.lower()
    rest = tokens[subcommand_idx + 1 :]

    for arg in rest:
        arg_lower = arg.lower()
        if _has_forbidden_git_option(arg_lower):
            return f"Using dangerous Git option '{arg}' is forbidden inside the sandbox."
        if arg in ("-u",) and sub_lower in ("fetch", "pull", "clone"):
            return f"Overriding upload-pack ('{arg}') in 'git {sub_lower}' is forbidden."

    if sub_lower in FORBIDDEN_GIT_SUBCOMMANDS:
        return f"Git subcommand 'git {sub_lower}' is strictly forbidden inside the sandbox."

    if sub_lower in READONLY_GIT_WRITE_SUBCOMMANDS or (
        sub_lower in ("branch", "tag") and _is_mutating_branch_or_tag(sub_lower, rest)
    ):
        return (
            f"Git write operation 'git {sub_lower}' is disabled inside the sandbox (.git is mounted read-only). "
            "Run Git write operations (add, commit, checkout, branch, push, etc.) from your host terminal."
        )

    if sub_lower == "remote":
        for arg in rest:
            if arg.startswith("-"):
                continue
            if arg.lower() in FORBIDDEN_REMOTE_ACTIONS:
                return f"Modifying Git remotes ('git remote {arg}') is forbidden inside the sandbox."
            break

    if sub_lower == "submodule":
        for arg in rest:
            if arg.startswith("-"):
                continue
            if arg.lower() in ("add", "set-url", "set-branch", "foreach"):
                return f"Git submodule action 'git submodule {arg}' is forbidden inside the sandbox."
            break

    if sub_lower == "config":
        return _inspect_git_config_arguments(rest)

    return None


def _split_shell_segments(cmd: str) -> list[str]:
    normalized_cmd = re.sub(r"\\\r?\n", " ", cmd)
    segments: list[str] = []

    probe = normalized_cmd
    for _ in range(6):
        matches = list(re.finditer(r"[\$<>]\(([^()]+)\)", probe))
        if not matches:
            break
        for match in matches:
            inner = match.group(1)
            if inner:
                segments.extend(re.split(r"(?:&&|\|\||[;\n|&])+", inner))
        probe = re.sub(r"[\$<>]\(([^()]+)\)", " ", probe)

    for match in re.finditer(r"`([^`]+)`", normalized_cmd):
        inner = match.group(1)
        if inner:
            segments.extend(re.split(r"(?:&&|\|\||[;\n|&])+", inner))

    segments.extend(re.split(r"(?:&&|\|\||[;\n|&])+", normalized_cmd))
    return [s.strip() for s in segments if s.strip()]


def _normalize_shell_tokens(raw_tokens: list[str]) -> list[str]:
    cleaned: list[str] = []
    for tok in raw_tokens:
        t = re.sub(r"^(?:[<>]?\()+", "", tok)
        t = re.sub(r"\)+$", "", t)
        if t in ("", "{", "}", "(", ")"):
            continue
        cleaned.append(t)
    return cleaned


def _matches_git_internal_token(tok: str, is_git_binary: bool) -> bool:
    if is_git_binary:
        return bool(
            re.search(
                r"(?:^|[^a-zA-Z0-9_-])\.git/(hooks|config|info|modules)(?:$|[^a-zA-Z0-9_])",
                tok,
                re.IGNORECASE,
            )
        )
    return bool(STANDALONE_DOT_GIT_PATTERN.search(tok))


def _matches_git_config_token(tok: str) -> bool:
    return bool(
        re.search(
            r"(?:^|[^a-zA-Z0-9_-])(\.gitconfig|\.config/git)(?:$|[^a-zA-Z0-9_])",
            tok,
            re.IGNORECASE,
        )
    )


def _matches_protected_sandbox_state_token(tok: str) -> bool:
    tok_to_check = tok
    if ".." not in tok:
        # Allow referencing the antigravity artifacts/scratch directory in shell commands
        # while still blocking any other ~/.gemini or /home/agent/.gemini reference.
        tok_to_check = re.sub(
            r"(?:/home/agent/|~/)\.gemini/antigravity/brain(?:/[^\s'\":;<>|&]*)?",
            "",
            tok,
            flags=re.IGNORECASE,
        )
    return bool(
        re.search(
            r"(?:^|[^a-zA-Z0-9_-])(/home/agent/\.(gemini|continue|config|local|cache|bashrc|profile|zshrc|ssh)|"
            r"~/\.(gemini|continue|config|local|cache|bashrc|profile|zshrc|ssh)|"
            r"\.gemini/config|\.continue/|\.local/share/code-server)(?:$|[^a-zA-Z0-9_-])",
            tok_to_check,
            re.IGNORECASE,
        )
    )


def _matches_customization_token(tok: str) -> bool:
    return bool(
        re.search(
            r"(?:^|[^a-zA-Z0-9_-])([._]agents?(?:/|$)|hooks\.json|mcp_config\.json|config\.worktree|\.continuerules)",
            tok,
            re.IGNORECASE,
        )
    )


def _matches_cicd_or_repo_meta_token(tok: str) -> bool:
    return bool(
        re.search(
            r"(?:^|[^a-zA-Z0-9_-])(?:"
            r"(?:\.github|\.circleci|\.buildkite|\.husky)(?:/|$)|"
            r"(?:\.gitlab-ci\.ya?ml|Jenkinsfile|azure-pipelines\.yml|\.travis\.yml|cloudbuild\.yaml|"
            r"bitbucket-pipelines\.yml|\.gitattributes|\.gitmodules|\.pre-commit-config\.yaml|"
            r"\.envrc|\.mise\.toml)(?:$|[^a-zA-Z0-9_-])"
            r")",
            tok,
            re.IGNORECASE,
        )
    )


def _matches_ide_config_token(tok: str) -> bool:
    return bool(
        re.search(
            r"(?:^|[^a-zA-Z0-9_-])(\.vscode/(?:tasks|launch|settings|extensions)\.json|\.idea/(?:tasks|workspace)\.xml)(?:$|[^a-zA-Z0-9_-])",
            tok,
            re.IGNORECASE,
        )
    )


def _find_secret_env_reference(tok: str) -> str | None:
    for env_file_match in re.finditer(
        r"(?:^|[/=\"'\s><:])(\.env(?:\.[a-zA-Z0-9_.-]+)?)(?:$|[^a-zA-Z0-9_.-])",
        tok,
    ):
        env_leaf = env_file_match.group(1).lower()
        if env_leaf not in SAFE_ENV_TEMPLATES:
            return env_leaf
    return None


def _check_shell_token_for_violations(
    tok: str,
    binary_name: str,
    allowed_workspaces: list[str] | None,
) -> str | None:
    if binary_name == "git":
        if _matches_git_internal_token(tok, is_git_binary=True):
            return f"Direct manipulation of '{tok}' (.git/hooks or .git/config) is forbidden."
    else:
        if _matches_git_internal_token(tok, is_git_binary=False):
            return f"Direct manipulation or traversal of '{tok}' (.git metadata/hooks) is forbidden."

    if _matches_git_config_token(tok):
        return f"Direct manipulation of Git configuration '{tok}' is forbidden."

    if re.search(r"(?:^|[^a-zA-Z0-9_-])/mnt/(lower|overlays)(?:$|[^a-zA-Z0-9_-])", tok):
        return f"Direct access to internal overlay mount directories '{tok}' is forbidden."

    if _matches_protected_sandbox_state_token(tok):
        return f"Direct manipulation of protected sandbox state '{tok}' is forbidden."

    if _matches_customization_token(tok):
        return f"Modifying agent customization or hook configuration '{tok}' is forbidden."

    if _matches_cicd_or_repo_meta_token(tok):
        return f"Modifying protected CI/CD or repository metadata path '{tok}' is forbidden."

    if _matches_ide_config_token(tok):
        return f"Modifying IDE host-execution configuration '{tok}' is forbidden."

    if _find_secret_env_reference(tok):
        return f"Accessing or modifying masked secret file '{tok}' is forbidden."

    if allowed_workspaces and "/workspaces/" in tok:
        ws_match = re.search(
            r"(/[^\s'\":;<>|&]*?/workspaces/[a-zA-Z0-9_.-]+|/workspaces/[a-zA-Z0-9_.-]+)",
            tok,
        )
        if ws_match:
            ref_ws = posixpath.normpath(ws_match.group(1)).rstrip("/")
            if not any(
                ref_ws == posixpath.normpath(w).rstrip("/")
                or ref_ws.startswith(posixpath.normpath(w).rstrip("/") + "/")
                for w in allowed_workspaces
                if isinstance(w, str) and w.strip()
            ):
                return f"Cross-repository shell access to '{tok}' outside active workspace is forbidden."

    return None


def _filter_git_commit_tokens(exec_tokens: list[str]) -> list[str]:
    non_msg_tokens: list[str] = []
    skip_next = False
    for t in exec_tokens[1:]:
        if skip_next:
            skip_next = False
            continue
        if t in ("-m", "--message") or re.match(r"^-[a-zA-Z]*m$", t):
            skip_next = True
            continue
        if t.startswith("-m") or t.startswith("--message="):
            continue
        non_msg_tokens.append(t)
    return non_msg_tokens


def _inspect_nested_interpreter(
    binary_name: str,
    exec_tokens: list[str],
    allowed_workspaces: list[str] | None,
    depth: int,
) -> str | None:
    if binary_name in SHELL_INTERPRETERS:
        for idx_tok, t in enumerate(exec_tokens[1:], start=1):
            if t == "-c" or (t.startswith("-") and not t.startswith("--") and "c" in t[1:]):
                if idx_tok + 1 < len(exec_tokens):
                    return _inspect_shell_command(
                        exec_tokens[idx_tok + 1],
                        allowed_workspaces=allowed_workspaces,
                        _depth=depth + 1,
                    )
    elif binary_name == "eval" and len(exec_tokens) > 1:
        return _inspect_shell_command(
            " ".join(exec_tokens[1:]),
            allowed_workspaces=allowed_workspaces,
            _depth=depth + 1,
        )
    return None


def _inspect_shell_segment(
    seg: str,
    allowed_workspaces: list[str] | None,
    depth: int,
) -> str | None:
    try:
        raw_tokens = shlex.split(seg, posix=True)
    except ValueError:
        if re.search(r"\bgit\b.*\b(push|send-pack|http-push|remote|config)\b", seg, re.IGNORECASE | re.DOTALL):
            return "Malformed shell quoting in a git command; blocked by security guard."
        if re.search(r"(\.git|\.gemini|code-server|[._]agents?|hooks\.json|mcp_config\.json)", seg, re.IGNORECASE):
            return "Malformed shell quoting referencing protected paths; blocked."
        return None

    tokens = _normalize_shell_tokens(raw_tokens)
    if not tokens:
        return None

    cmd_idx = 0
    saw_home_override = False
    while cmd_idx < len(tokens):
        tok = tokens[cmd_idx]
        if "=" in tok and not tok.startswith("-") and tok.split("=", 1)[0].isidentifier():
            var_name = tok.split("=", 1)[0]
            if FORBIDDEN_ENV_VARS_PATTERN.match(f"{var_name}="):
                return f"Setting '{var_name}' is forbidden inside the sandbox."
            if var_name.upper() == "HOME":
                saw_home_override = True
            cmd_idx += 1
            continue
        if tok.lower() in TRANSPARENT_CMD_WRAPPERS:
            cmd_idx += 1
            continue
        break

    if cmd_idx >= len(tokens):
        return None

    exec_tokens = tokens[cmd_idx:]
    binary_name = posixpath.basename(exec_tokens[0]).lower()

    if saw_home_override and binary_name == "git":
        return "Overriding HOME environment variable for Git commands is forbidden."

    nested_denial = _inspect_nested_interpreter(binary_name, exec_tokens, allowed_workspaces, depth)
    if nested_denial:
        return nested_denial

    if binary_name == "git":
        denial = _inspect_git_tokens(exec_tokens)
        if denial:
            return denial
        check_tokens = _filter_git_commit_tokens(exec_tokens)
    else:
        for idx_tok, t in enumerate(exec_tokens[1:], start=1):
            if posixpath.basename(t).lower() == "git":
                denial = _inspect_git_tokens(exec_tokens[idx_tok:])
                if denial:
                    return denial
                break
        check_tokens = exec_tokens

    for tok in check_tokens:
        tok_denial = _check_shell_token_for_violations(tok, binary_name, allowed_workspaces)
        if tok_denial:
            return tok_denial

    return None


def _inspect_shell_command(
    cmd: str,
    allowed_workspaces: list[str] | None = None,
    _depth: int = 0,
) -> str | None:
    if not cmd.strip():
        return None
    if _depth > 5:
        return "Shell command nesting depth exceeded; blocked by security guard."

    decoded_cmd = _decode_shell_escapes(cmd)

    env_match = FORBIDDEN_ENV_VARS_PATTERN.search(decoded_cmd)
    if env_match:
        return f"Setting '{env_match.group(1)}' is forbidden inside the sandbox."

    if re.search(
        r"\|\s*(?:env\s+)?(?:/usr/bin/|/bin/)?(?:sh|bash|zsh|dash|ksh|ash|csh|tcsh|eval|source)\b",
        decoded_cmd,
        re.IGNORECASE,
    ):
        return "Piping output directly into a shell interpreter is forbidden inside the sandbox."

    for seg in _split_shell_segments(decoded_cmd):
        seg_denial = _inspect_shell_segment(seg, allowed_workspaces, _depth)
        if seg_denial:
            return seg_denial

    return None


def _collect_path_args(obj: Any) -> list[str]:
    paths: list[str] = []
    if isinstance(obj, dict):
        for k, v in obj.items():
            if isinstance(k, str) and k.lower() in PATH_ARG_KEYS:
                if isinstance(v, str):
                    paths.append(v)
                elif isinstance(v, list):
                    paths.extend(item for item in v if isinstance(item, str))
            elif isinstance(v, (dict, list)):
                paths.extend(_collect_path_args(v))
    elif isinstance(obj, list):
        for item in obj:
            if isinstance(item, (dict, list)):
                paths.extend(_collect_path_args(item))
    return paths


def evaluate_tool_call(payload: dict[str, Any]) -> dict[str, Any]:
    if not isinstance(payload, dict):
        return {"decision": "deny", "reason": "Invalid payload type."}

    tool_call = payload.get("toolCall")
    if not isinstance(tool_call, dict):
        return {"decision": "deny", "reason": "Missing or invalid 'toolCall' object."}

    tool_name = str(tool_call.get("name", ""))
    tool_name_lower = tool_name.lower()
    args = tool_call.get("args") or {}
    if not isinstance(args, dict):
        return {"decision": "deny", "reason": "Invalid 'args' in toolCall."}

    raw_workspaces = payload.get("workspacePaths")
    allowed_workspaces: list[str] | None = (
        [w for w in raw_workspaces if isinstance(w, str) and w.strip()]
        if isinstance(raw_workspaces, list)
        else None
    )

    if tool_name_lower == "run_command":
        if args.get("BypassSandbox") is True:
            return {
                "decision": "deny",
                "reason": "BypassSandbox=True is disabled by enterprise sandbox policy.",
            }
        cmd = str(args.get("CommandLine", ""))
        denial = _inspect_shell_command(cmd, allowed_workspaces=allowed_workspaces)
        if denial:
            return {"decision": "deny", "reason": denial}
        return {"decision": "allow"}

    if tool_name_lower == "manage_task":
        task_input = args.get("Input") or args.get("input")
        if isinstance(task_input, str) and task_input.strip():
            denial = _inspect_shell_command(task_input, allowed_workspaces=allowed_workspaces)
            if denial:
                return {"decision": "deny", "reason": denial}
        return {"decision": "allow"}

    is_write_tool = tool_name_lower in WRITE_TOOL_NAMES or bool(
        re.search(
            r"(write|edit|create|replace|patch|append|save|delete|remove|move|rename|copy)",
            tool_name_lower,
        )
    )
    candidate_paths = _collect_path_args(args)

    if is_write_tool:
        if not candidate_paths:
            return {
                "decision": "deny",
                "reason": f"File mutation tool '{tool_name}' requires a valid target path argument.",
            }
        for val in candidate_paths:
            denial = _check_file_path(val, allowed_workspaces=allowed_workspaces)
            if denial:
                return {"decision": "deny", "reason": denial}
    else:
        for val in candidate_paths:
            leaf = posixpath.basename(val.strip().replace("\\", "/")).lower()
            if _is_secret_env_filename(leaf):
                return {
                    "decision": "deny",
                    "reason": f"Accessing or modifying masked secret file '{val}' is forbidden.",
                }

    return {"decision": "allow"}


def main() -> None:
    try:
        raw = sys.stdin.read()
        if not raw.strip():
            decision = {"decision": "deny", "reason": "Empty hook payload on stdin."}
        else:
            payload = json.loads(raw)
            decision = evaluate_tool_call(payload)
    except Exception as exc:
        decision = {
            "decision": "deny",
            "reason": f"Security hook failed closed: {exc}",
        }
    sys.stdout.write(json.dumps(decision) + "\n")


if __name__ == "__main__":
    main()
