#requires -version 5.1
[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$Root = 'C:\ProjFSRoot',

    [Parameter(Mandatory = $false)]
    [string]$LogPath = 'C:\Sandbox\Write\provider.log',

    # Wipe and recreate the root before starting. Needed for repeat runs,
    # because the root stays marked as a virtualization root and hello.txt
    # becomes a real (hydrated) file after first access.
    [switch]$ResetRoot
)

$ErrorActionPreference = 'Stop'

# ---- Prerequisite checks (this is where ProjFS-in-Sandbox usually dies) ----

if (-not [Environment]::Is64BitProcess) {
    throw "Run this in 64-bit PowerShell. Current process is 32-bit. Launch %WINDIR%\System32\WindowsPowerShell\v1.0\powershell.exe (not SysWOW64)."
}

# PrjFlt is a file system minifilter, not a Win32 service, so Get-Service does
# not list it (PowerShell 5.1 Get-Service enumerates Win32 services only).
# Verify it with the filter manager instead, matching Sandbox-Bootstrap.ps1.
function Test-PrjFltLoaded {
    $filters = (& fltmc.exe filters 2>&1 | Out-String)
    return ($filters -match '(?im)PrjFlt|ProjFS')
}

if (-not (Test-PrjFltLoaded)) {
    Write-Warning "PrjFlt minifilter is not attached. Trying to load it."
    & fltmc.exe load PrjFlt 2>&1 | Out-Host
    if (-not (Test-PrjFltLoaded)) {
        throw "PrjFlt minifilter is not loaded and could not be loaded. Run Sandbox-Bootstrap.ps1 first to side-load and load the filter."
    }
}

# Confirm the DLL is actually loadable before we JIT the native calls.
$dll = Join-Path $env:WINDIR 'System32\ProjectedFSLib.dll'
if (-not (Test-Path -LiteralPath $dll)) {
    throw "ProjectedFSLib.dll not found at $dll. ProjFS is not present in this environment."
}

# ---- Reset the root so repeat runs behave the same as the first ----

if ($ResetRoot -and (Test-Path -LiteralPath $Root)) {
    Write-Host "Resetting root: $Root"
    # A marked virtualization root can hold reparse points; remove recursively.
    cmd /c "rmdir /s /q `"$Root`"" | Out-Null
}

# ---- Your provider (C# unchanged) ----

$source = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class BasicProjFSProvider
{
    private const int S_OK = 0;
    private const int E_FILE_NOT_FOUND = unchecked((int)0x80070002);
    private const uint FILE_ATTRIBUTE_ARCHIVE = 0x20;
    private const int PRJ_PLACEHOLDER_ID_LENGTH = 128;

    private static readonly byte[] FileContent = Encoding.UTF8.GetBytes(
        "Hello from a basic ProjFS provider running inside Windows Sandbox.\r\n");

    private static string _logPath;
    private static IntPtr _context = IntPtr.Zero;
    private static readonly ManualResetEvent StopEvent = new ManualResetEvent(false);

    [StructLayout(LayoutKind.Sequential)]
    private struct PRJ_CALLBACK_DATA
    {
        public uint Size;
        public uint Flags;
        public IntPtr NamespaceVirtualizationContext;
        public int CommandId;
        public Guid FileId;
        public Guid DataStreamId;
        public IntPtr FilePathName;
        public IntPtr VersionInfo;
        public uint TriggeringProcessId;
        public IntPtr TriggeringProcessImageFileName;
        public IntPtr InstanceContext;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PRJ_FILE_BASIC_INFO
    {
        [MarshalAs(UnmanagedType.U1)] public bool IsDirectory;
        public long FileSize;
        public long CreationTime;
        public long LastAccessTime;
        public long LastWriteTime;
        public long ChangeTime;
        public uint FileAttributes;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PRJ_PLACEHOLDER_VERSION_INFO
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = PRJ_PLACEHOLDER_ID_LENGTH)]
        public byte[] ProviderID;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = PRJ_PLACEHOLDER_ID_LENGTH)]
        public byte[] ContentID;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PRJ_PLACEHOLDER_INFO
    {
        public PRJ_FILE_BASIC_INFO FileBasicInfo;
        public uint EaBufferSize;
        public uint OffsetToFirstEa;
        public uint SecurityBufferSize;
        public uint OffsetToSecurityDescriptor;
        public uint StreamsInfoBufferSize;
        public uint OffsetToFirstStreamInfo;
        public PRJ_PLACEHOLDER_VERSION_INFO VersionInfo;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 1)]
        public byte[] VariableData;
    }

    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int StartDirectoryEnumerationCallback(IntPtr callbackData, IntPtr enumerationId);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int EndDirectoryEnumerationCallback(IntPtr callbackData, IntPtr enumerationId);
    [UnmanagedFunctionPointer(CallingConvention.Winapi, CharSet = CharSet.Unicode)]
    private delegate int GetDirectoryEnumerationCallback(IntPtr callbackData, IntPtr enumerationId, string searchExpression, IntPtr dirEntryBufferHandle);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int GetPlaceholderInfoCallback(IntPtr callbackData);
    [UnmanagedFunctionPointer(CallingConvention.Winapi)]
    private delegate int GetFileDataCallback(IntPtr callbackData, ulong byteOffset, uint length);

    [StructLayout(LayoutKind.Sequential)]
    private struct PRJ_CALLBACKS
    {
        public StartDirectoryEnumerationCallback StartDirectoryEnumerationCallback;
        public EndDirectoryEnumerationCallback EndDirectoryEnumerationCallback;
        public GetDirectoryEnumerationCallback GetDirectoryEnumerationCallback;
        public GetPlaceholderInfoCallback GetPlaceholderInfoCallback;
        public GetFileDataCallback GetFileDataCallback;
        public IntPtr QueryFileNameCallback;
        public IntPtr NotificationCallback;
        public IntPtr CancelCommandCallback;
    }

    private static StartDirectoryEnumerationCallback _startEnum = StartEnum;
    private static EndDirectoryEnumerationCallback _endEnum = EndEnum;
    private static GetDirectoryEnumerationCallback _getEnum = GetEnum;
    private static GetPlaceholderInfoCallback _getPlaceholder = GetPlaceholder;
    private static GetFileDataCallback _getFileData = GetFileData;

    [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int PrjMarkDirectoryAsPlaceholder(
        string rootPathName,
        string targetPathName,
        IntPtr versionInfo,
        ref Guid virtualizationInstanceID);

    [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int PrjStartVirtualizing(
        string virtualizationRootPath,
        ref PRJ_CALLBACKS callbacks,
        IntPtr instanceContext,
        IntPtr options,
        out IntPtr namespaceVirtualizationContext);

    [DllImport("ProjectedFSLib.dll", ExactSpelling = true)]
    private static extern void PrjStopVirtualizing(IntPtr namespaceVirtualizationContext);

    [DllImport("ProjectedFSLib.dll", CharSet = CharSet.Unicode, ExactSpelling = true)]
    private static extern int PrjWritePlaceholderInfo(
        IntPtr namespaceVirtualizationContext,
        string destinationFileName,
        ref PRJ_PLACEHOLDER_INFO placeholderInfo,
        uint placeholderInfoSize);

    [DllImport("ProjectedFSLib.dll", ExactSpelling = true)]
    private static extern IntPtr PrjAllocateAlignedBuffer(IntPtr namespaceVirtualizationContext, UIntPtr size);

    [DllImport("ProjectedFSLib.dll", ExactSpelling = true)]
    private static extern void PrjFreeAlignedBuffer(IntPtr buffer);

    [DllImport("ProjectedFSLib.dll", ExactSpelling = true)]
    private static extern int PrjWriteFileData(
        IntPtr namespaceVirtualizationContext,
        ref Guid dataStreamId,
        IntPtr buffer,
        ulong byteOffset,
        uint length);

    private static void Log(string message)
    {
        string line = DateTime.Now.ToString("s") + " " + message;
        Console.WriteLine(line);
        try { File.AppendAllText(_logPath, line + Environment.NewLine); } catch { }
    }

    private static string GetRelativePath(IntPtr callbackData)
    {
        PRJ_CALLBACK_DATA data = (PRJ_CALLBACK_DATA)Marshal.PtrToStructure(callbackData, typeof(PRJ_CALLBACK_DATA));
        return Marshal.PtrToStringUni(data.FilePathName) ?? String.Empty;
    }

    private static PRJ_PLACEHOLDER_INFO CreatePlaceholderInfo()
    {
        long now = DateTime.UtcNow.ToFileTimeUtc();
        PRJ_PLACEHOLDER_INFO info = new PRJ_PLACEHOLDER_INFO();
        info.FileBasicInfo = new PRJ_FILE_BASIC_INFO
        {
            IsDirectory = false,
            FileSize = FileContent.LongLength,
            CreationTime = now,
            LastAccessTime = now,
            LastWriteTime = now,
            ChangeTime = now,
            FileAttributes = FILE_ATTRIBUTE_ARCHIVE
        };
        info.VersionInfo = new PRJ_PLACEHOLDER_VERSION_INFO
        {
            ProviderID = new byte[PRJ_PLACEHOLDER_ID_LENGTH],
            ContentID = new byte[PRJ_PLACEHOLDER_ID_LENGTH]
        };
        byte[] provider = Encoding.ASCII.GetBytes("SandboxBasicProjFS-v1");
        byte[] content = Encoding.ASCII.GetBytes("hello-v1");
        Array.Copy(provider, info.VersionInfo.ProviderID, provider.Length);
        Array.Copy(content, info.VersionInfo.ContentID, content.Length);
        info.VariableData = new byte[1];
        return info;
    }

    private static uint PlaceholderInfoSize()
    {
        // ProjFS requires at least sizeof(PRJ_PLACEHOLDER_INFO), which includes
        // the trailing VariableData element plus struct padding. Passing the
        // smaller OffsetOf(VariableData) yields ERROR_INSUFFICIENT_BUFFER (0x8007007A).
        return checked((uint)Marshal.SizeOf(typeof(PRJ_PLACEHOLDER_INFO)));
    }

    private static int WriteHelloPlaceholder(IntPtr namespaceContext)
    {
        PRJ_PLACEHOLDER_INFO info = CreatePlaceholderInfo();
        return PrjWritePlaceholderInfo(namespaceContext, "hello.txt", ref info, PlaceholderInfoSize());
    }

    private static int StartEnum(IntPtr callbackData, IntPtr enumerationId) { return S_OK; }
    private static int EndEnum(IntPtr callbackData, IntPtr enumerationId) { return S_OK; }
    private static int GetEnum(IntPtr callbackData, IntPtr enumerationId, string searchExpression, IntPtr dirEntryBufferHandle) { return S_OK; }

    private static int GetPlaceholder(IntPtr callbackData)
    {
        string path = GetRelativePath(callbackData);
        if (!String.Equals(path, "hello.txt", StringComparison.OrdinalIgnoreCase)) return E_FILE_NOT_FOUND;
        PRJ_CALLBACK_DATA data = (PRJ_CALLBACK_DATA)Marshal.PtrToStructure(callbackData, typeof(PRJ_CALLBACK_DATA));
        return WriteHelloPlaceholder(data.NamespaceVirtualizationContext);
    }

    private static int GetFileData(IntPtr callbackData, ulong byteOffset, uint length)
    {
        string path = GetRelativePath(callbackData);
        if (!String.Equals(path, "hello.txt", StringComparison.OrdinalIgnoreCase)) return E_FILE_NOT_FOUND;

        if (byteOffset >= (ulong)FileContent.Length) return S_OK;
        uint available = (uint)Math.Min((ulong)length, (ulong)FileContent.Length - byteOffset);
        PRJ_CALLBACK_DATA data = (PRJ_CALLBACK_DATA)Marshal.PtrToStructure(callbackData, typeof(PRJ_CALLBACK_DATA));
        IntPtr buffer = PrjAllocateAlignedBuffer(data.NamespaceVirtualizationContext, new UIntPtr(available));
        if (buffer == IntPtr.Zero) return unchecked((int)0x8007000E);

        try
        {
            byte[] segment = new byte[available];
            Buffer.BlockCopy(FileContent, checked((int)byteOffset), segment, 0, checked((int)available));
            Marshal.Copy(segment, 0, buffer, checked((int)available));
            Guid streamId = data.DataStreamId;
            int hr = PrjWriteFileData(data.NamespaceVirtualizationContext, ref streamId, buffer, byteOffset, available);
            Log("Hydrated hello.txt, offset=" + byteOffset + ", length=" + available + ", hr=0x" + hr.ToString("X8"));
            return hr;
        }
        finally
        {
            PrjFreeAlignedBuffer(buffer);
        }
    }

    public static void Run(string root, string logPath)
    {
        _logPath = logPath;
        Directory.CreateDirectory(Path.GetDirectoryName(logPath));
        Directory.CreateDirectory(root);

        Guid instanceId = new Guid("7D5517D6-8C4A-4D76-B7B3-1FD49633E8B2");
        int hr = PrjMarkDirectoryAsPlaceholder(root, null, IntPtr.Zero, ref instanceId);
        if (hr != S_OK && hr != unchecked((int)0x800700B7))
            throw new InvalidOperationException("PrjMarkDirectoryAsPlaceholder failed: 0x" + hr.ToString("X8"));

        PRJ_CALLBACKS callbacks = new PRJ_CALLBACKS
        {
            StartDirectoryEnumerationCallback = _startEnum,
            EndDirectoryEnumerationCallback = _endEnum,
            GetDirectoryEnumerationCallback = _getEnum,
            GetPlaceholderInfoCallback = _getPlaceholder,
            GetFileDataCallback = _getFileData,
            QueryFileNameCallback = IntPtr.Zero,
            NotificationCallback = IntPtr.Zero,
            CancelCommandCallback = IntPtr.Zero
        };

        hr = PrjStartVirtualizing(root, ref callbacks, IntPtr.Zero, IntPtr.Zero, out _context);
        if (hr != S_OK) throw new InvalidOperationException("PrjStartVirtualizing failed: 0x" + hr.ToString("X8"));

        try
        {
            hr = WriteHelloPlaceholder(_context);
            if (hr != S_OK && hr != unchecked((int)0x800700B7))
                throw new InvalidOperationException("PrjWritePlaceholderInfo failed: 0x" + hr.ToString("X8"));

            Log("Provider started. Root=" + root + "; projected file=hello.txt");
            Console.CancelKeyPress += delegate(object sender, ConsoleCancelEventArgs e) { e.Cancel = true; StopEvent.Set(); };
            StopEvent.WaitOne();
        }
        finally
        {
            if (_context != IntPtr.Zero) PrjStopVirtualizing(_context);
            Log("Provider stopped.");
        }
    }
}
'@

Add-Type -TypeDefinition $source -Language CSharp

try {
    [BasicProjFSProvider]::Run($Root, $LogPath)
}
catch [System.DllNotFoundException] {
    Write-Error "ProjectedFSLib.dll could not be loaded. ProjFS is not active in this session (PrjFlt not loaded). Run Sandbox-Bootstrap.ps1 first. Original: $($_.Exception.Message)"
}
catch {
    # Surface the real HRESULT / inner exception instead of a generic failure.
    Write-Error ("Provider failed: " + $_.Exception.GetType().FullName + ": " + $_.Exception.Message)
    if ($_.Exception.InnerException) {
        Write-Error ("Inner: " + $_.Exception.InnerException.Message)
    }
    throw
}
