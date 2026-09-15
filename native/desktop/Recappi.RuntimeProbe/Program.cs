// The console apphost resolves the exact copied application runtimeconfig before
// entering managed code. No windows, account data or application state are opened.
if (args.Length != 1 || args[0] != "--check-runtime") return 2;
Console.WriteLine(typeof(System.Windows.Window).Assembly.GetName().Name);
Console.WriteLine(typeof(System.Windows.Forms.NotifyIcon).Assembly.GetName().Name);
return 0;
