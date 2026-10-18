// The console apphost resolves the exact copied application runtimeconfig before
// entering managed code. No windows, account data or application state are opened.
if (args.Length != 1 || args[0] != "--check-runtime") return 2;
Console.WriteLine(System.Runtime.InteropServices.RuntimeInformation.FrameworkDescription);
return 0;
