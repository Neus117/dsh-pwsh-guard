using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Text;
using System.Text.RegularExpressions;
using System.Web.Script.Serialization;

// dsh-pwsh-guard: the PowerShell entry guard for DeepSeek Harness (DSH).
//
// DSH runs every pwsh command through `@deepseek-ai/dsh-pwsh-sandbox`, whose
// `pwshPath` config points at THIS executable. DSH therefore always invokes us
// with the exact argv it would have given to PowerShell 7:
//
//   pwsh-guard.exe -NoLogo -NoProfile -NonInteractive -Command <preamble+command>
//
// We inspect the command string before any child process exists. A blocked
// command exits 3 and never starts PowerShell. An allowed command is forwarded
// verbatim to the real PowerShell 7 and its exit code is returned unchanged.
//
// The guard is a tripwire against accidental destructive commands (the
// `$home`-style mistake), not a security sandbox: text matching cannot see
// inside scripts, `Invoke-Expression`, or arbitrary binaries. See README.md.
//
// Language level: C# 5 (compiled by the .NET Framework csc.exe that ships with
// every Windows machine), so no string interpolation, no null-conditional, no
// expression-bodied members.

internal sealed class GuardRule
{
    public string Id { get; set; }
    public string Reason { get; set; }
    public Regex Pattern { get; set; }
}

internal sealed class GuardConfig
{
    public string Source { get; set; }
    public string ConfigError { get; set; }
    public string LogPath { get; set; }
    public string AllowMarker { get; set; }
    public int MaxLoggedCommandChars { get; set; }
    public long MaxLogBytes { get; set; }
    public List<GuardRule> Rules { get; set; }
    public List<string> ProtectedRoots { get; set; }
    public List<string> PwshCandidates { get; set; }

    public GuardConfig()
    {
        Rules = new List<GuardRule>();
        ProtectedRoots = new List<string>();
        PwshCandidates = new List<string>();
        MaxLoggedCommandChars = 4000;
        MaxLogBytes = 5L * 1024L * 1024L;
        AllowMarker = "dsh-guard:allow-destructive";
    }
}

internal sealed class Decision
{
    public bool Blocked { get; set; }
    public string RuleId { get; set; }
    public string Reason { get; set; }
    public string Marker { get; set; }

    public Decision(bool blocked, string ruleId, string reason)
    {
        Blocked = blocked;
        RuleId = ruleId;
        Reason = reason;
    }
}

internal static class Program
{
    internal const string Tag = "[pwsh-guard]";

    // Exit codes: 0..N = child PowerShell; 3 = blocked by the guard;
    // 4 = the guard could not start a real PowerShell; 5 = internal guard error.
    private const int ExitBlocked = 3;
    private const int ExitNoPwsh = 4;
    private const int ExitInternal = 5;

    private static int Main(string[] args)
    {
        try
        {
            if (args.Length >= 1 && (args[0] == "--guard-info" || args[0] == "--guard-selftest"))
            {
                return PrintInfo(GuardConfigLoader.Load());
            }

            GuardConfig config = GuardConfigLoader.Load();
            string command = CommandText(args);
            Decision decision = Evaluate(command, config);

            AuditLog.Append(config, decision, command);

            if (decision.Blocked)
            {
                // One machine-parsable line then one human line. Deliberately no
                // hint about the allow marker: a model must ask the user first.
                Console.Error.WriteLine(Tag + " BLOCKED rule=" + decision.RuleId + " reason=" + decision.Reason);
                Console.Error.WriteLine(Tag + " destructive command refused before it started; ask the user how to proceed (rules: guard.rules.json, docs: README.md)");
                return ExitBlocked;
            }

            string real = ResolvePwsh(config);
            if (real == null)
            {
                Console.Error.WriteLine(Tag + " no PowerShell executable found; candidates=" + string.Join(" | ", config.PwshCandidates.ToArray()));
                return ExitNoPwsh;
            }

            return Forward(real, args);
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(Tag + " internal error: " + ex.Message);
            return ExitInternal;
        }
    }

    // ---------------------------------------------------------------- decision

    internal static Decision Evaluate(string command, GuardConfig config)
    {
        GuardRule hit = null;
        foreach (GuardRule rule in config.Rules)
        {
            if (rule.Pattern.IsMatch(command))
            {
                hit = rule;
                break;
            }
        }
        if (hit == null)
        {
            return new Decision(false, "none", "clean");
        }

        // A protected root anywhere in the command outranks the allow marker:
        // deleting %USERPROFILE% is never an operation to wave through. This is
        // what makes the 2026-11-23 incident class impossible even with a marker.
        string root = FindProtectedRoot(command, config.ProtectedRoots);
        if (root != null)
        {
            return new Decision(true, hit.Id, "protected-root:" + root);
        }

        if (config.AllowMarker.Length > 0
            && command.IndexOf(config.AllowMarker, StringComparison.OrdinalIgnoreCase) >= 0)
        {
            Decision allowed = new Decision(false, hit.Id, "allow-marker");
            allowed.Marker = config.AllowMarker;
            return allowed;
        }

        return new Decision(true, hit.Id, hit.Reason);
    }

    internal static string FindProtectedRoot(string command, List<string> roots)
    {
        foreach (string root in roots)
        {
            if (root.Length == 0) continue;
            if (command.IndexOf(root, StringComparison.OrdinalIgnoreCase) >= 0) return root;
        }
        return null;
    }

    /// <summary>The command text DSH handed to pwsh: the argument after -Command/-c.</summary>
    internal static string CommandText(string[] args)
    {
        for (int i = 0; i < args.Length; i++)
        {
            if (string.Equals(args[i], "-Command", StringComparison.OrdinalIgnoreCase)
                || string.Equals(args[i], "-c", StringComparison.OrdinalIgnoreCase))
            {
                return i + 1 < args.Length ? args[i + 1] : string.Empty;
            }
        }
        return string.Join(" ", args);
    }

    // ------------------------------------------------------------------ spawn

    private static string ResolvePwsh(GuardConfig config)
    {
        foreach (string candidate in config.PwshCandidates)
        {
            if (candidate.Length == 0) continue;
            if (File.Exists(candidate)) return candidate;
        }
        return null;
    }

    private static int Forward(string real, string[] args)
    {
        ProcessStartInfo start = new ProcessStartInfo();
        start.FileName = real;
        start.UseShellExecute = false;
        start.CreateNoWindow = false;

        StringBuilder arguments = new StringBuilder();
        foreach (string arg in args)
        {
            if (arguments.Length > 0) arguments.Append(' ');
            arguments.Append(Quote(arg));
        }
        start.Arguments = arguments.ToString();

        using (Process child = Process.Start(start))
        {
            if (child == null)
            {
                Console.Error.WriteLine(Tag + " failed to start " + real);
                return ExitNoPwsh;
            }
            child.WaitForExit();
            return child.ExitCode;
        }
    }

    /// <summary>Windows CreateProcess argument quoting (CommandLineToArgvW rules).</summary>
    internal static string Quote(string value)
    {
        if (value.Length == 0) return "\"\"";
        StringBuilder sb = new StringBuilder();
        sb.Append('"');
        int backslashes = 0;
        foreach (char ch in value)
        {
            if (ch == '\\')
            {
                backslashes++;
                continue;
            }
            if (ch == '"')
            {
                sb.Append('\\', backslashes * 2 + 1);
                sb.Append('"');
                backslashes = 0;
                continue;
            }
            sb.Append('\\', backslashes);
            backslashes = 0;
            sb.Append(ch);
        }
        sb.Append('\\', backslashes * 2);
        sb.Append('"');
        return sb.ToString();
    }

    // ------------------------------------------------------------------- info

    private static int PrintInfo(GuardConfig config)
    {
        Console.WriteLine("dsh-pwsh-guard " + Version);
        Console.WriteLine("exe           = " + ExecutablePath());
        Console.WriteLine("config        = " + config.Source + (config.ConfigError == null ? "" : " (ERROR: " + config.ConfigError + ")"));
        Console.WriteLine("log           = " + AuditLog.Expand(config.LogPath));
        Console.WriteLine("allowMarker   = " + config.AllowMarker);
        Console.WriteLine("rules         = " + config.Rules.Count);
        foreach (GuardRule rule in config.Rules)
        {
            Console.WriteLine("  - " + rule.Id + " : " + rule.Pattern);
        }
        Console.WriteLine("protectedRoots= " + string.Join(", ", config.ProtectedRoots.ToArray()));
        Console.WriteLine("pwshCandidates:");
        foreach (string candidate in config.PwshCandidates)
        {
            Console.WriteLine("  - " + candidate + (File.Exists(candidate) ? "  [found]" : "  [missing]"));
        }
        return 0;
    }

    internal const string Version = "3.0.1";

    internal static string ExecutablePath()
    {
        try
        {
            return System.Reflection.Assembly.GetExecutingAssembly().Location;
        }
        catch
        {
            return Process.GetCurrentProcess().MainModule.FileName;
        }
    }

    internal static string BaseDirectory()
    {
        string path = ExecutablePath();
        if (string.IsNullOrEmpty(path)) return Environment.CurrentDirectory;
        string dir = Path.GetDirectoryName(path);
        return string.IsNullOrEmpty(dir) ? Environment.CurrentDirectory : dir;
    }
}

internal static class AuditLog
{
    internal static void Append(GuardConfig config, Decision decision, string command)
    {
        try
        {
            string path = Expand(config.LogPath);
            if (string.IsNullOrEmpty(path)) return;
            string dir = Path.GetDirectoryName(path);
            if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir)) Directory.CreateDirectory(dir);

            if (File.Exists(path) && new FileInfo(path).Length > config.MaxLogBytes) Rotate(path);

            string decisionText = decision.Blocked ? "blocked" : (decision.Reason == "allow-marker" ? "allowed-by-marker" : "run");
            StringBuilder line = new StringBuilder(256);
            line.Append("{\"time\":\"").Append(DateTime.Now.ToString("yyyy-MM-ddTHH:mm:ss.fffzzz", CultureInfo.InvariantCulture)).Append('"');
            line.Append(",\"decision\":\"").Append(decisionText).Append('"');
            line.Append(",\"rule\":\"").Append(Json(decision.RuleId)).Append('"');
            line.Append(",\"reason\":\"").Append(Json(decision.Reason)).Append('"');
            line.Append(",\"pid\":").Append(Process.GetCurrentProcess().Id);
            line.Append(",\"cwd\":\"").Append(Json(Environment.CurrentDirectory)).Append('"');
            line.Append(",\"command\":\"").Append(Json(Truncate(command, config.MaxLoggedCommandChars))).Append('"');
            line.Append('}');

            File.AppendAllText(path, line.ToString() + Environment.NewLine, new UTF8Encoding(false));
        }
        catch
        {
            // Logging must never break the command path. A blocked command is
            // still blocked; only the audit trail is lost.
        }
    }

    private static void Rotate(string path)
    {
        string previous = path + ".1";
        try
        {
            if (File.Exists(previous)) File.Delete(previous);
            File.Move(path, previous);
        }
        catch
        {
            // Keep appending to the oversized file rather than losing entries.
        }
    }

    internal static string Expand(string path)
    {
        if (string.IsNullOrEmpty(path)) return null;
        string expanded = Environment.ExpandEnvironmentVariables(path);
        // A relative logPath is relative to the guard, never to the caller's
        // working directory (DSH commands run in the user's project folder).
        if (!Path.IsPathRooted(expanded)) expanded = Path.Combine(Program.BaseDirectory(), expanded);
        return expanded;
    }

    private static string Truncate(string value, int max)
    {
        if (value == null) return string.Empty;
        return value.Length <= max ? value : value.Substring(0, max) + "...[truncated]";
    }

    private static string Json(string value)
    {
        if (value == null) return string.Empty;
        StringBuilder sb = new StringBuilder(value.Length + 16);
        foreach (char ch in value)
        {
            switch (ch)
            {
                case '"': sb.Append("\\\""); break;
                case '\\': sb.Append("\\\\"); break;
                case '\n': sb.Append("\\n"); break;
                case '\r': sb.Append("\\r"); break;
                case '\t': sb.Append("\\t"); break;
                default:
                    if (ch < 0x20) sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
                    else sb.Append(ch);
                    break;
            }
        }
        return sb.ToString();
    }
}

internal static class GuardConfigLoader
{
    internal const string ConfigFileName = "guard.rules.json";

    internal static GuardConfig Load()
    {
        GuardConfig config = Default();
        string path = Path.Combine(Program.BaseDirectory(), ConfigFileName);
        config.Source = path;
        if (!File.Exists(path))
        {
            config.Source = path + " (missing, using built-in defaults)";
            return config;
        }
        try
        {
            string text = File.ReadAllText(path, new UTF8Encoding(false));
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            serializer.MaxJsonLength = 4 * 1024 * 1024;
            Dictionary<string, object> root = serializer.DeserializeObject(text) as Dictionary<string, object>;
            if (root == null) throw new FormatException("root must be a JSON object");

            if (root.ContainsKey("logPath")) config.LogPath = Convert.ToString(root["logPath"]);
            if (root.ContainsKey("allowMarker")) config.AllowMarker = Convert.ToString(root["allowMarker"]);
            if (root.ContainsKey("maxLoggedCommandChars")) config.MaxLoggedCommandChars = Convert.ToInt32(root["maxLoggedCommandChars"]);
            if (root.ContainsKey("maxLogBytes")) config.MaxLogBytes = Convert.ToInt64(root["maxLogBytes"]);

            List<string> roots = Strings(root, "protectedRoots");
            if (roots != null) config.ProtectedRoots = roots;

            List<string> candidates = Strings(root, "pwshCandidates");
            if (candidates != null) config.PwshCandidates = candidates;

            List<object> rules = Objects(root, "rules");
            if (rules != null)
            {
                List<GuardRule> parsed = new List<GuardRule>();
                foreach (object item in rules)
                {
                    Dictionary<string, object> entry = item as Dictionary<string, object>;
                    if (entry == null) continue;
                    string id = Convert.ToString(Field(entry, "id"));
                    string pattern = Convert.ToString(Field(entry, "pattern"));
                    string reason = Convert.ToString(Field(entry, "reason"));
                    bool enabled = true;
                    object flag = Field(entry, "enabled");
                    if (flag != null) enabled = Convert.ToBoolean(flag);
                    if (!enabled || string.IsNullOrEmpty(pattern)) continue;
                    if (string.IsNullOrEmpty(id)) id = "rule-" + parsed.Count;
                    GuardRule rule = new GuardRule();
                    rule.Id = id;
                    rule.Reason = string.IsNullOrEmpty(reason) ? id : reason;
                    rule.Pattern = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
                    parsed.Add(rule);
                }
                if (parsed.Count > 0) config.Rules = parsed;
            }
        }
        catch (Exception ex)
        {
            config.ConfigError = ex.Message;
            GuardConfig fallback = Default();
            fallback.Source = config.Source;
            fallback.ConfigError = config.ConfigError;
            return fallback;
        }
        return config;
    }

    private static object Field(Dictionary<string, object> entry, string key)
    {
        object value;
        return entry.TryGetValue(key, out value) ? value : null;
    }

    private static List<string> Strings(Dictionary<string, object> root, string key)
    {
        object value;
        if (!root.TryGetValue(key, out value)) return null;
        // JavaScriptSerializer materialises JSON arrays as object[].
        object[] items = value as object[];
        if (items == null) return null;
        List<string> result = new List<string>();
        foreach (object item in items)
        {
            string text = Convert.ToString(item);
            if (!string.IsNullOrEmpty(text)) result.Add(text);
        }
        return result;
    }

    private static List<object> Objects(Dictionary<string, object> root, string key)
    {
        object value;
        if (!root.TryGetValue(key, out value)) return null;
        object[] items = value as object[];
        if (items == null) return null;
        return new List<object>(items);
    }

    /// <summary>
    /// Built-in defaults, identical to guard.rules.json. Present so the exe keeps
    /// working if the JSON is deleted or malformed.
    ///
    /// Destructive verbs are anchored at statement position (start of text, or
    /// after ; | &amp;&amp; | { newline) on purpose: matching them anywhere also
    /// blocks harmless commands that merely quote the word, such as grepping a
    /// file for "Remove-Item". The 2026-11-23 accident command had the verb at
    /// statement position, and so does every scripted form of it.
    /// </summary>
    internal static GuardConfig Default()
    {
        GuardConfig config = new GuardConfig();
        config.LogPath = Path.Combine(Program.BaseDirectory(), "logs", "guard.jsonl");
        config.PwshCandidates = new List<string>(new string[]
        {
            @"C:\Program Files\PowerShell\7\pwsh.exe",
            @"C:\Program Files\PowerShell\7-preview\pwsh.exe",
            Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\Microsoft\WindowsApps\Microsoft.PowerShell_8wekyb3d8bbwe\pwsh.exe"),
            Environment.ExpandEnvironmentVariables(@"%LOCALAPPDATA%\Microsoft\WindowsApps\pwsh.exe"),
        });
        config.ProtectedRoots = new List<string>(new string[]
        {
            "$home", "$env:USERPROFILE", "$env:APPDATA", "$env:LOCALAPPDATA",
            "$env:ProgramData", "%USERPROFILE%", "%APPDATA%", "%LOCALAPPDATA%",

        });
        config.Rules = new List<GuardRule>(new GuardRule[]
        {
            Rule("delete-cmdlet", @"(?:^|[;\r\n|&{]\s*)(?:Remove-Item|Remove-ItemProperty|Clear-Content|Clear-RecycleBin)\b",
                 "deletes files, keys, content or the recycle bin"),
            Rule("delete-alias", @"(?:^|[;\r\n|&{]\s*)(?:del|erase|rd|rmdir|rm|ri)(?:\s|$)",
                 "cmdlet alias that deletes"),
            Rule("move-cmdlet", @"(?:^|[;\r\n|&{]\s*)(?:Move-Item|mv)(?:\s|$)",
                 "moves/overwrites paths"),
            Rule("git-clean", @"(?:^|[;\r\n|&{]\s*)git\s+clean\b",
                 "deletes untracked files"),
            Rule("robocopy-mirror", @"\brobocopy\b[\s\S]*?/(?:MIR|MOV|PURGE)\b",
                 "mirror/purge deletes destination content"),
            Rule("taskkill-tree", @"\btaskkill\b[\s\S]*?/T\b",
                 "kills a whole process tree"),
            Rule("script-bypass", @"\b(?:powershell|pwsh)(?:\.exe)?\b[\s\S]*?\s-(?:file|encodedcommand|enc)\b",
                 "hides the real command inside a script file or encoded payload"),
        });
        return config;
    }

    private static GuardRule Rule(string id, string pattern, string reason)
    {
        GuardRule rule = new GuardRule();
        rule.Id = id;
        rule.Reason = reason;
        rule.Pattern = new Regex(pattern, RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
        return rule;
    }
}
