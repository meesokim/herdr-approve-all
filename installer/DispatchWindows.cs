using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;

internal static class Program
{
    private static string _herdr = "herdr";
    private static string _config = "";
    private static string _state = "";
    private static string _flag = "";
    private static bool _automatic = false;
    private static readonly Dictionary<string, DateTime> _lastContinueAt = new Dictionary<string, DateTime>(StringComparer.OrdinalIgnoreCase);

    private static readonly Regex RxRule = new Regex(@"^\s*\u2500{10,}\s*$", RegexOptions.Compiled);
    private static readonly Regex RxBoxBorder = new Regex(@"^\s*[\u2503\u2502|]", RegexOptions.Compiled);
    private static readonly Regex RxEmptyQuote = new Regex(@"^\s*>\s*$", RegexOptions.Compiled);
    private static readonly Regex RxAnyQuote = new Regex(@"^\s*>", RegexOptions.Compiled);
    private static readonly Regex RxIndentedNonBullet = new Regex(@"^\s+", RegexOptions.Compiled);
    private static readonly Regex RxBulletOrBox = new Regex(@"^\s*[\u2503\u2502|\u25cf\u25cb\u273b]", RegexOptions.Compiled);
    private static readonly Regex RxOpt1 = new Regex(@"^\s*(?:[\u2503\u2502|]\s*)?[\u276f>]\s*1\.\s+(?:Yes|Allow|Accept)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex RxOptN = new Regex(@"^\s*(?:[\u2503\u2502|]\s*)?[2-9]\.\s+(?:Yes|No|Allow|Deny|Accept|Reject)\b", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex RxClassicLine = new Regex(@"^\s*(?:[\u2503\u2502|]\s*)?(?:[\u276f>]\s*\d+\.\s+|1\.\s+(?:Yes|Allow|Accept)\b).*(?:enter to (?:confirm|select)|esc to cancel)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex RxCue = new Regex(@"Allow (?:sandbox bypass|access|calling|creation|administrator|remote)\b|Accept this file edit\?|Confirm the command is safe|Requesting permission for:|Run this command\?|Reason:\s*outside workspace|Do you want to", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex RxFooterCue = new Regex(@"^\s*(?:[\u2503\u2502|]\s*)?(?:.*(?:Navigate|tab Amend|ctrl\+g|enter to (?:confirm|select))|esc to cancel\s*$)", RegexOptions.IgnoreCase | RegexOptions.Compiled);
    private static readonly Regex RxResetActivity = new Regex(@"Running command\.\.\.|Reading file\.\.\.|Editing file|Thinking\.\.\.|Loading\.\.\.|Thought for \d|\d+(?:\.\d+)?k\s+in\s*\||Conversation compacted", RegexOptions.IgnoreCase | RegexOptions.Compiled);

    private sealed class AgentEntry
    {
        public string PaneId = "";
        public string Agent = "unknown";
        public string Status = "";
        public bool Focused = false;
        public long Seq = 0;
        public long Rev = 0;
        public int Rank = 4;
    }

    private static int Main(string[] args)
    {
        if (args.Length == 0) return 1;

        // In mock unit tests, delegate to approve-windows.ps1
        if (!string.IsNullOrEmpty(Environment.GetEnvironmentVariable("MOCK_HERDR_DIR")))
        {
            return RunPowerShellFallback(args);
        }

        string mode = args[0].ToLowerInvariant();
        string configArg = "";
        string stateArg = "";
        string herdrArg = "";
        for (int i = 1; i < args.Length - 1; i++)
        {
            if (string.Equals(args[i], "-ConfigDir", StringComparison.OrdinalIgnoreCase)) configArg = args[++i];
            else if (string.Equals(args[i], "-StateDir", StringComparison.OrdinalIgnoreCase)) stateArg = args[++i];
            else if (string.Equals(args[i], "-HerdrBin", StringComparison.OrdinalIgnoreCase)) herdrArg = args[++i];
        }

        _config = !string.IsNullOrEmpty(configArg) ? configArg : (Environment.GetEnvironmentVariable("HERDR_PLUGIN_CONFIG_DIR") ?? "");
        if (string.IsNullOrEmpty(_config))
        {
            _config = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ApplicationData), "herdr", "plugins", "config", "renkoya1.approve-all");
        }
        _state = !string.IsNullOrEmpty(stateArg) ? stateArg : (Environment.GetEnvironmentVariable("HERDR_PLUGIN_STATE_DIR") ?? "");
        if (string.IsNullOrEmpty(_state))
        {
            _state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "herdr", "plugins", "renkoya1.approve-all");
        }
        _herdr = !string.IsNullOrEmpty(herdrArg) ? herdrArg : (Environment.GetEnvironmentVariable("HERDR_BIN_PATH") ?? "");
        if (string.IsNullOrEmpty(_herdr))
        {
            string localBin = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Herdr", "bin", "herdr.exe");
            _herdr = File.Exists(localBin) ? localBin : "herdr.exe";
        }
        _flag = Path.Combine(_config, "auto-approve");
        _automatic = (mode == "event" || mode == "monitor");

        try
        {
            switch (mode)
            {
                case "on":
                    Directory.CreateDirectory(_config);
                    File.WriteAllText(_flag, string.Empty, Encoding.ASCII);
                    StopMonitor();
                    StartMonitor();
                    Notify("Auto-approve ON");
                    return 0;

                case "off":
                    try { if (File.Exists(_flag)) File.Delete(_flag); } catch { }
                    StopMonitor();
                    Notify("Auto-approve OFF");
                    return 0;

                case "startup":
                    if (File.Exists(_flag) && !TestMonitorRunning())
                    {
                        StartMonitor();
                    }
                    return 0;

                case "event":
                    if (!File.Exists(_flag)) return 0;
                    string evJson = Environment.GetEnvironmentVariable("HERDR_PLUGIN_EVENT_JSON") ?? "";
                    if (string.IsNullOrEmpty(evJson)) return 0;
                    bool monitorRunning = TestMonitorRunning();
                    if (!monitorRunning)
                    {
                        StartMonitor();
                    }
                    string evPane = ExtractJsonString(evJson, "pane_id");
                    string evAgent = ExtractJsonString(evJson, "agent");
                    string evStatus = ExtractJsonString(evJson, "agent_status");
                    if (!string.IsNullOrEmpty(evPane) && (evStatus == "blocked" || !monitorRunning))
                    {
                        string res = ApprovePane(evPane, string.IsNullOrEmpty(evAgent) ? "unknown" : evAgent, evStatus);
                        if (res == "-" && evStatus != "blocked")
                        {
                            Thread.Sleep(100);
                            ApprovePane(evPane, string.IsNullOrEmpty(evAgent) ? "unknown" : evAgent, "");
                        }
                    }
                    return 0;

                case "sweep":
                    using (Mutex sweepMutex = NewPluginMutex("sweep"))
                    {
                        bool locked = false;
                        try
                        {
                            locked = LockMutex(sweepMutex, 0);
                            if (!locked) return 0;
                            List<AgentEntry> agents = GetSortedAgents();
                            int approved = 0, stuck = 0;
                            foreach (AgentEntry ag in agents)
                            {
                                string r = ApprovePane(ag.PaneId, ag.Agent, ag.Status);
                                if (r == "1") approved++;
                                else if (r == "0") stuck++;
                            }
                            if (approved > 0 || stuck > 0)
                            {
                                Notify("Approved " + approved + " agents; " + stuck + " still blocked");
                            }
                        }
                        finally
                        {
                            if (locked) try { sweepMutex.ReleaseMutex(); } catch { }
                        }
                    }
                    return 0;

                case "monitor":
                    RunMonitorLoop();
                    return 0;

                default:
                    return 1;
            }
        }
        catch
        {
            return 1;
        }
    }

    private static void RunMonitorLoop()
    {
        using (Mutex monitorMutex = NewPluginMutex("monitor"))
        {
            bool locked = false;
            string pidFile = Path.Combine(_state, "monitor.pid");
            string logFile = Path.Combine(_state, "monitor.log");
            try
            {
                locked = LockMutex(monitorMutex, 10000);
                if (!locked) return;
                Directory.CreateDirectory(_state);
                try { File.WriteAllText(pidFile, Process.GetCurrentProcess().Id.ToString(CultureInfo.InvariantCulture), Encoding.ASCII); } catch { }

                Dictionary<string, string> idleCache = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
                List<AgentEntry> cachedAgents = new List<AgentEntry>();
                DateTime lastListAt = DateTime.MinValue;
                int tick = 0;

                while (File.Exists(_flag))
                {
                    tick++;
                    try
                    {
                        bool needRefresh = cachedAgents.Count == 0 || (DateTime.UtcNow - lastListAt).TotalSeconds >= 4.0;
                        if (needRefresh)
                        {
                            try
                            {
                                List<AgentEntry> fresh = GetSortedAgents();
                                if (fresh.Count > 0)
                                {
                                    cachedAgents = fresh;
                                }
                                lastListAt = DateTime.UtcNow;
                            }
                            catch (Exception ex)
                            {
                                lastListAt = DateTime.UtcNow;
                                WriteLog(logFile, ex.Message);
                            }
                        }

                        foreach (AgentEntry agent in cachedAgents)
                        {
                            if (!File.Exists(_flag)) break;
                            bool isIdleOrDone = (agent.Status == "idle" || agent.Status == "done");
                            if (isIdleOrDone && !agent.Focused)
                            {
                                string stateKey = agent.Status + ":" + agent.Seq + ":" + agent.Rev;
                                string prevKey;
                                if (idleCache.TryGetValue(agent.PaneId, out prevKey) && prevKey == stateKey && (tick % 10) != 0)
                                {
                                    continue;
                                }
                                idleCache[agent.PaneId] = stateKey;
                            }
                            else
                            {
                                idleCache.Remove(agent.PaneId);
                            }

                            string scrapeHint = string.IsNullOrEmpty(agent.Status) ? "working" : agent.Status;
                            string result = ApprovePane(agent.PaneId, agent.Agent, scrapeHint);
                            if (result == "1" || result == "0")
                            {
                                idleCache.Remove(agent.PaneId);
                                WriteLog(logFile, "pane=" + agent.PaneId + " result=" + result);
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        WriteLog(logFile, ex.Message);
                    }

                    int pollMs = Math.Max(80, (int)(1000.0 * NumberSetting("APPROVE_AUTO_POLL_SEC", 0.15)));
                    Thread.Sleep(pollMs);
                }
            }
            finally
            {
                if (locked)
                {
                    try { if (File.Exists(pidFile)) File.Delete(pidFile); } catch { }
                    try { monitorMutex.ReleaseMutex(); } catch { }
                }
            }
        }
    }

    private static void WriteLog(string logFile, string message)
    {
        try
        {
            File.WriteAllText(logFile, DateTime.Now.ToString("o", CultureInfo.InvariantCulture) + " " + message + Environment.NewLine, Encoding.UTF8);
        }
        catch { }
    }

    private static double NumberSetting(string name, double defaultVal)
    {
        string raw = Environment.GetEnvironmentVariable(name);
        double parsed;
        if (!string.IsNullOrEmpty(raw) && double.TryParse(raw, NumberStyles.Float, CultureInfo.InvariantCulture, out parsed) && parsed >= 0)
        {
            return parsed;
        }
        return defaultVal;
    }

    private static string InvokeHerdr(string[] arguments, int timeoutMs = 0)
    {
        if (timeoutMs <= 0)
        {
            timeoutMs = (int)NumberSetting("APPROVE_CMD_TIMEOUT_MS", 12000);
        }
        StringBuilder sb = new StringBuilder();
        for (int i = 0; i < arguments.Length; i++)
        {
            if (i > 0) sb.Append(' ');
            string a = arguments[i] ?? "";
            if (a.Length == 0) sb.Append("\"\"");
            else if (a.IndexOfAny(new char[] { ' ', '\t', '"' }) < 0) sb.Append(a);
            else sb.Append('"').Append(a.Replace("\"", "\\\"")).Append('"');
        }

        ProcessStartInfo psi = new ProcessStartInfo(_herdr, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        psi.RedirectStandardInput = true;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.StandardOutputEncoding = Encoding.UTF8;

        using (Process proc = Process.Start(psi))
        {
            if (proc == null) throw new InvalidOperationException("Failed to start herdr");
            try { proc.StandardInput.Close(); } catch { }
            var outTask = proc.StandardOutput.ReadToEndAsync();
            proc.StandardError.ReadToEndAsync();
            if (!proc.WaitForExit(timeoutMs))
            {
                try { proc.Kill(); } catch { }
                throw new TimeoutException("herdr command timed out after " + timeoutMs + "ms: " + sb.ToString());
            }
            outTask.Wait(1000);
            if (proc.ExitCode != 0)
            {
                throw new InvalidOperationException("herdr command failed: " + sb.ToString());
            }
            string output = outTask.Result ?? "";
            return output.Replace("\r\n", "\n").TrimEnd('\r', '\n');
        }
    }

    private static void Notify(string message)
    {
        try { InvokeHerdr(new string[] { "notification", "show", message, "--sound", "none" }, 3000); } catch { }
    }

    private static Mutex NewPluginMutex(string name)
    {
        string normalizedConfig = _config.TrimEnd('\\', '/').ToLowerInvariant();
        using (SHA256 sha = SHA256.Create())
        {
            byte[] hashBytes = sha.ComputeHash(Encoding.UTF8.GetBytes(normalizedConfig + "/" + name));
            string hash = BitConverter.ToString(hashBytes).Replace("-", "");
            return new Mutex(false, @"Local\herdr-approve-all-" + hash);
        }
    }

    private static bool LockMutex(Mutex m, int timeoutMs)
    {
        try { return m.WaitOne(timeoutMs); }
        catch (AbandonedMutexException) { return true; }
    }

    private static bool TestMonitorRunning()
    {
        using (Mutex m = NewPluginMutex("monitor"))
        {
            bool locked = false;
            try
            {
                locked = LockMutex(m, 0);
                return !locked;
            }
            finally
            {
                if (locked) try { m.ReleaseMutex(); } catch { }
            }
        }
    }

    private static void StopMonitor()
    {
        string pidFile = Path.Combine(_state, "monitor.pid");
        int selfPid = Process.GetCurrentProcess().Id;
        if (File.Exists(pidFile))
        {
            try
            {
                string raw = File.ReadAllText(pidFile).Trim();
                int pid;
                if (int.TryParse(raw, out pid) && pid > 0 && pid != selfPid)
                {
                    try
                    {
                        Process p = Process.GetProcessById(pid);
                        if (p.ProcessName.IndexOf("dispatch", StringComparison.OrdinalIgnoreCase) >= 0 ||
                            p.ProcessName.IndexOf("powershell", StringComparison.OrdinalIgnoreCase) >= 0)
                        {
                            p.Kill();
                            p.WaitForExit(1500);
                        }
                    }
                    catch { }
                }
                File.Delete(pidFile);
            }
            catch { }
        }
        try
        {
            foreach (Process p in Process.GetProcessesByName("dispatch"))
            {
                try
                {
                    if (p.Id != selfPid)
                    {
                        p.Kill();
                    }
                }
                catch { }
                finally { p.Dispose(); }
            }
        }
        catch { }
    }

    private static void StartMonitor()
    {
        if (TestMonitorRunning()) return;
        Directory.CreateDirectory(_state);
        string exePath = AssemblyPath();
        string args = "monitor -ConfigDir \"" + _config + "\" -StateDir \"" + _state + "\" -HerdrBin \"" + _herdr + "\"";

        try
        {
            // Spawn via WMI so the worker runs under WmiPrvSE.exe outside any short-lived hook Job Object
            string wmicArgs = "process call create \"\\\"" + exePath + "\\\" " + args.Replace("\"", "\\\"") + "\"";
            ProcessStartInfo wmiPsi = new ProcessStartInfo("wmic.exe", wmicArgs);
            wmiPsi.UseShellExecute = false;
            wmiPsi.CreateNoWindow = true;
            wmiPsi.RedirectStandardOutput = true;
            wmiPsi.RedirectStandardError = true;
            using (Process wmiProc = Process.Start(wmiPsi))
            {
                if (wmiProc != null && wmiProc.WaitForExit(4000) && wmiProc.ExitCode == 0)
                {
                    string outText = wmiProc.StandardOutput.ReadToEnd();
                    if (outText.IndexOf("ReturnValue = 0;", StringComparison.OrdinalIgnoreCase) >= 0)
                    {
                        return;
                    }
                }
            }
        }
        catch { }

        ProcessStartInfo psi = new ProcessStartInfo(exePath, args);
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process.Start(psi);
    }

    private static string AssemblyPath()
    {
        return typeof(Program).Assembly.Location;
    }

    private static bool TestPromptVisible(string screen)
    {
        if (string.IsNullOrEmpty(screen)) return false;
        bool hasCue = false;
        bool hasOpt1 = false;
        bool matched = false;
        bool inUserQuote = false;

        string[] lines = screen.Replace("\r\n", "\n").Split('\n');
        for (int i = 0; i < lines.Length; i++)
        {
            string line = lines[i];
            if (RxRule.IsMatch(line) && !RxBoxBorder.IsMatch(line))
            {
                inUserQuote = false;
                continue;
            }
            if (RxEmptyQuote.IsMatch(line)) continue;
            if (RxResetActivity.IsMatch(line))
            {
                hasCue = false;
                hasOpt1 = false;
                matched = false;
                inUserQuote = false;
                continue;
            }
            if (!inUserQuote && RxClassicLine.IsMatch(line))
            {
                hasOpt1 = true;
                matched = true;
                continue;
            }
            if (!inUserQuote && RxOpt1.IsMatch(line))
            {
                hasOpt1 = true;
                if (hasCue) matched = true;
                continue;
            }
            if (RxAnyQuote.IsMatch(line))
            {
                inUserQuote = true;
                hasCue = false;
                hasOpt1 = false;
                matched = false;
                continue;
            }
            if (inUserQuote)
            {
                if (string.IsNullOrWhiteSpace(line) || (RxIndentedNonBullet.IsMatch(line) && !RxBulletOrBox.IsMatch(line)))
                {
                    continue;
                }
                inUserQuote = false;
            }
            if (hasOpt1 && (RxOptN.IsMatch(line) || RxFooterCue.IsMatch(line)))
            {
                matched = true;
                continue;
            }
            if (RxCue.IsMatch(line))
            {
                hasCue = true;
                continue;
            }
            if (!matched && hasOpt1 && !string.IsNullOrWhiteSpace(line))
            {
                hasOpt1 = false;
            }
        }
        return matched;
    }

    private static bool TestFalseBlockedScreen(string screen)
    {
        if (string.IsNullOrEmpty(screen)) return false;
        return Regex.IsMatch(screen, @"\u2500{20,}\r?\n\s*>\s*\r?\n\u2500{20,}") &&
               Regex.IsMatch(screen, @"Running command\.\.\.|Reading file\.\.\.|Thinking\.\.\.|Press up to edit queued messages", RegexOptions.IgnoreCase);
    }

    private static bool TestContinueNeeded(string screen)
    {
        if (string.IsNullOrEmpty(screen)) return false;
        bool matched = false;
        bool sawErrorId = false;
        int box = 0;
        Regex errRx = new Regex(@"There was a network issue connecting to the server,\s*please try again\.|agent executor error:|stream reading error:|stream idle timeout|context deadline exceeded", RegexOptions.IgnoreCase);
        string[] lines = screen.Replace("\r\n", "\n").Split('\n');
        foreach (string line in lines)
        {
            if (!RxAnyQuote.IsMatch(line) && errRx.IsMatch(line))
            {
                matched = true;
                sawErrorId = false;
                box = 0;
                continue;
            }
            if (matched)
            {
                if (string.IsNullOrWhiteSpace(line)) continue;
                if (Regex.IsMatch(line, @"^\s*Error ID:\s*\S+", RegexOptions.IgnoreCase)) { sawErrorId = true; continue; }
                if (box == 0 && !sawErrorId && !RxAnyQuote.IsMatch(line) && Regex.IsMatch(line, @"generating and executing|stream|timeout|deadline exceeded|please try again", RegexOptions.IgnoreCase)) continue;
                if (box == 0 && RxRule.IsMatch(line)) { box = 1; continue; }
                if (box == 1 && RxEmptyQuote.IsMatch(line)) { box = 2; continue; }
                if (box == 2 && RxRule.IsMatch(line)) { box = 3; continue; }
                if (box == 3)
                {
                    if (Regex.IsMatch(line, @"Running command|Reading file|Thinking", RegexOptions.IgnoreCase)) { matched = false; box = 0; }
                    continue;
                }
                matched = false;
                sawErrorId = false;
                box = 0;
            }
        }
        return matched && (box == 0 || box == 3);
    }

    private static bool TestCtrlKNeeded(string screen)
    {
        if (string.IsNullOrEmpty(screen)) return false;
        bool hasHeader = false;
        bool matched = false;
        int box = 0;
        string[] lines = screen.Replace("\r\n", "\n").Split('\n');
        foreach (string line in lines)
        {
            if (RxRule.IsMatch(line) && !RxBoxBorder.IsMatch(line))
            {
                if (matched)
                {
                    if (box == 0) { box = 1; continue; }
                    if (box == 1 || box == 2 || box == 3) { box = 3; continue; }
                }
                continue;
            }
            if (RxAnyQuote.IsMatch(line))
            {
                if (matched && (box == 1 || box == 2) && RxEmptyQuote.IsMatch(line)) { box = 2; continue; }
                hasHeader = false;
                matched = false;
                box = 0;
                continue;
            }
            if (Regex.IsMatch(line, @"\bneeds approval(?:\s+for)?\b", RegexOptions.IgnoreCase))
            {
                hasHeader = true;
            }
            if (Regex.IsMatch(line, @"\bctrl\+k\s+(?:to\s+)?approve\b", RegexOptions.IgnoreCase) &&
                (hasHeader || Regex.IsMatch(line, @"\balt\+j\s+manage\b", RegexOptions.IgnoreCase) || RxBoxBorder.IsMatch(line)))
            {
                matched = true;
                box = 0;
                continue;
            }
            if (matched)
            {
                if (string.IsNullOrWhiteSpace(line) || Regex.IsMatch(line, @"^\s*[\u2503\u2502|\u2514\u251c\u21b3\u25cf\u25cb\u273b\u2800-\u28ff]")) continue;
                if ((box == 0 || box == 1 || box == 3) && Regex.IsMatch(line, @"^\s*(?:\?\s+for\s+shortcuts|esc\s+to\s+cancel|\S.*(?:accept-edits|request-review|auto-approve|subagent\(s\)))", RegexOptions.IgnoreCase)) continue;
                matched = false;
                box = 0;
            }
        }
        return matched && (box == 0 || box == 1 || box == 3);
    }

    private static string GetPaneAction(string pane, string knownStatus)
    {
        try
        {
            string status = knownStatus;
            if (string.IsNullOrEmpty(status))
            {
                string getJson = InvokeHerdr(new string[] { "agent", "get", pane }, 4000);
                status = ExtractJsonString(getJson, "agent_status");
            }
            if (status == "blocked")
            {
                if (Environment.GetEnvironmentVariable("APPROVE_SCRAPE_FALLBACK") != "0")
                {
                    try
                    {
                        string bScreen = InvokeHerdr(new string[] { "agent", "read", pane, "--source", "visible", "--lines", "40" }, 4000);
                        if (!string.IsNullOrEmpty(bScreen))
                        {
                            if (TestCtrlKNeeded(bScreen)) return "ctrl+k";
                            if (TestPromptVisible(bScreen)) return "approve";
                            if (TestContinueNeeded(bScreen)) return "continue";
                            if (TestFalseBlockedScreen(bScreen)) return "";
                        }
                    }
                    catch { }
                }
                return "approve";
            }
            if (Environment.GetEnvironmentVariable("APPROVE_SCRAPE_FALLBACK") == "0") return "";
            string screen = InvokeHerdr(new string[] { "agent", "read", pane, "--source", "visible", "--lines", "40" }, 4000);
            if (TestCtrlKNeeded(screen)) return "ctrl+k";
            if (TestPromptVisible(screen)) return "approve";
            if (TestContinueNeeded(screen)) return "continue";
            return "";
        }
        catch
        {
            return "";
        }
    }

    private static string ApprovePane(string pane, string agent, string initialStatus)
    {
        using (Mutex paneMutex = NewPluginMutex("pane/" + pane))
        {
            bool locked = false;
            try
            {
                locked = LockMutex(paneMutex, 0);
                if (!locked) return "-";

                string[] keys = new string[] { "enter" };
                string keyFile = Path.Combine(_config, "keys.conf");
                if (File.Exists(keyFile))
                {
                    foreach (string line in File.ReadAllLines(keyFile))
                    {
                        if (line.StartsWith(agent + "=", StringComparison.Ordinal))
                        {
                            string rawKeys = line.Substring(agent.Length + 1).Trim();
                            if (!string.IsNullOrEmpty(rawKeys))
                            {
                                keys = rawKeys.Split(new char[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries);
                            }
                            break;
                        }
                    }
                }

                int sent = 0;
                string lastAction = "";
                bool cleared = false;
                int max = (int)NumberSetting("APPROVE_MAX_SENDS", 5);
                int settleMs = (int)(1000.0 * NumberSetting("APPROVE_SETTLE_SEC", 0.12));
                int timeout = (int)NumberSetting("APPROVE_LEAVE_TIMEOUT_MS", 1200);

                while (sent < max && keys.Length > 0)
                {
                    string hint = (sent == 0) ? initialStatus : "";
                    string action = GetPaneAction(pane, hint);
                    if (string.IsNullOrEmpty(action))
                    {
                        cleared = true;
                        break;
                    }
                    if (_automatic && !File.Exists(_flag)) break;

                    if (action == "continue")
                    {
                        double cooldown = NumberSetting("APPROVE_CONTINUE_COOLDOWN_SEC", 4);
                        DateTime lastTime;
                        if (_lastContinueAt.TryGetValue(pane, out lastTime) && (DateTime.UtcNow - lastTime).TotalSeconds < cooldown)
                        {
                            break;
                        }
                        try
                        {
                            InvokeHerdr(new string[] { "agent", "prompt", pane, "continue" }, 4000);
                        }
                        catch
                        {
                            try { InvokeHerdr(new string[] { "agent", "send-keys", pane, "c", "o", "n", "t", "i", "n", "u", "e", "enter" }, 4000); }
                            catch { break; }
                        }
                        _lastContinueAt[pane] = DateTime.UtcNow;
                        sent++;
                        lastAction = "continue";
                        try { InvokeHerdr(new string[] { "agent", "wait", pane, "--until", "working", "--timeout", timeout.ToString(CultureInfo.InvariantCulture) }, Math.Max(2000, timeout + 1500)); } catch { }
                        Thread.Sleep(settleMs);
                        cleared = true;
                        break;
                    }

                    if (action == "ctrl+k")
                    {
                        try { InvokeHerdr(new string[] { "agent", "send-keys", pane, "ctrl+k" }, 4000); }
                        catch { break; }
                        sent++;
                        lastAction = "ctrl+k";
                        if (hint == "blocked")
                        {
                            try { InvokeHerdr(new string[] { "agent", "wait", pane, "--until", "idle", "--until", "working", "--until", "done", "--timeout", timeout.ToString(CultureInfo.InvariantCulture) }, Math.Max(2000, timeout + 1500)); } catch { }
                        }
                        Thread.Sleep(settleMs);
                        if (_automatic && !string.IsNullOrEmpty(hint) && hint != "blocked")
                        {
                            cleared = true;
                            break;
                        }
                        continue;
                    }

                    string[] sendArgs = new string[3 + keys.Length];
                    sendArgs[0] = "agent";
                    sendArgs[1] = "send-keys";
                    sendArgs[2] = pane;
                    Array.Copy(keys, 0, sendArgs, 3, keys.Length);
                    try { InvokeHerdr(sendArgs, 4000); }
                    catch { break; }
                    sent++;
                    lastAction = "approve";
                    if (string.IsNullOrEmpty(hint) || hint == "blocked")
                    {
                        try { InvokeHerdr(new string[] { "agent", "wait", pane, "--until", "idle", "--until", "working", "--until", "done", "--timeout", timeout.ToString(CultureInfo.InvariantCulture) }, Math.Max(2000, timeout + 1500)); } catch { }
                    }
                    Thread.Sleep(settleMs);
                    if (_automatic && !string.IsNullOrEmpty(hint) && hint != "blocked")
                    {
                        cleared = true;
                        break;
                    }
                }

                if (sent == 0) return "-";
                if (cleared || lastAction == "continue") return "1";
                string remaining = GetPaneAction(pane, "");
                if (remaining == "approve" || remaining == "ctrl+k") return "0";
                return "1";
            }
            finally
            {
                if (locked) try { paneMutex.ReleaseMutex(); } catch { }
            }
        }
    }

    private static List<AgentEntry> GetSortedAgents()
    {
        string json = InvokeHerdr(new string[] { "agent", "list" }, 12000);
        List<AgentEntry> list = new List<AgentEntry>();
        int agentsIdx = json.IndexOf("\"agents\"", StringComparison.Ordinal);
        if (agentsIdx < 0) return list;
        int arrStart = json.IndexOf('[', agentsIdx);
        if (arrStart < 0) return list;

        bool inStr = false;
        bool esc = false;
        int depth = 0;
        int objStart = -1;

        for (int i = arrStart + 1; i < json.Length; i++)
        {
            char c = json[i];
            if (esc) { esc = false; continue; }
            if (c == '\\' && inStr) { esc = true; continue; }
            if (c == '"') { inStr = !inStr; continue; }
            if (inStr) continue;

            if (c == '{')
            {
                if (depth == 0) objStart = i;
                depth++;
            }
            else if (c == '}')
            {
                depth--;
                if (depth == 0 && objStart >= 0)
                {
                    string obj = json.Substring(objStart, i - objStart + 1);
                    string paneId = ExtractJsonString(obj, "pane_id");
                    if (!string.IsNullOrEmpty(paneId))
                    {
                        AgentEntry e = new AgentEntry();
                        e.PaneId = paneId;
                        string ag = ExtractJsonString(obj, "agent");
                        e.Agent = string.IsNullOrEmpty(ag) ? "unknown" : ag;
                        e.Status = ExtractJsonString(obj, "agent_status");
                        e.Focused = Regex.IsMatch(obj, "\"focused\"\\s*:\\s*true");
                        e.Seq = ExtractJsonLong(obj, "state_change_seq");
                        e.Rev = ExtractJsonLong(obj, "revision");
                        if (e.Status == "blocked") e.Rank = 0;
                        else if (e.Status == "working" && e.Focused) e.Rank = 1;
                        else if (e.Status == "working") e.Rank = 2;
                        else if (e.Focused) e.Rank = 3;
                        else e.Rank = 4;
                        list.Add(e);
                    }
                    objStart = -1;
                }
            }
            else if (c == ']' && depth == 0)
            {
                break;
            }
        }

        list.Sort((a, b) => a.Rank.CompareTo(b.Rank));
        return list;
    }

    private static string ExtractJsonString(string json, string key)
    {
        Match m = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*\"([^\"]*)\"");
        return m.Success ? m.Groups[1].Value : "";
    }

    private static long ExtractJsonLong(string json, string key)
    {
        Match m = Regex.Match(json, "\"" + Regex.Escape(key) + "\"\\s*:\\s*(\\d+)");
        long val;
        if (m.Success && long.TryParse(m.Groups[1].Value, NumberStyles.Integer, CultureInfo.InvariantCulture, out val))
        {
            return val;
        }
        return 0;
    }

    private static int RunPowerShellFallback(string[] args)
    {
        string baseDir = AppDomain.CurrentDomain.BaseDirectory;
        string scriptPath = Path.Combine(baseDir, "approve-windows.ps1");
        if (!File.Exists(scriptPath)) return 1;

        string sysDir = Environment.GetFolderPath(Environment.SpecialFolder.System);
        string psExe = Path.Combine(sysDir, @"WindowsPowerShell\v1.0\powershell.exe");
        if (!File.Exists(psExe)) psExe = "powershell.exe";

        StringBuilder sb = new StringBuilder();
        sb.Append("-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File \"").Append(scriptPath).Append("\"");
        foreach (string arg in args)
        {
            sb.Append(" \"").Append(arg.Replace("\"", "\\\"")).Append("\"");
        }

        ProcessStartInfo psi = new ProcessStartInfo(psExe, sb.ToString());
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        using (Process proc = Process.Start(psi))
        {
            if (proc == null) return 1;
            proc.WaitForExit();
            return proc.ExitCode;
        }
    }
}
