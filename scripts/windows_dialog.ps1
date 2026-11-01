param(
    [ValidateSet('folder', 'file')][string]$Mode = 'folder',
    [string]$InitialDirectory,
    [Alias('CancelTest')][switch]$CancelForTest,
    [switch]$ValidateOnly
)
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
function Write-Response($Value) {
    [Console]::Out.WriteLine((ConvertTo-Json -InputObject $Value -Compress))
}
if ($CancelForTest) { Write-Response @{ cancelled = $true }; exit 0 }
try {
    if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        throw 'The system file dialog must be started with powershell.exe -STA.'
    }
    $nativeCode = @"
using System;
using System.Runtime.InteropServices;

namespace MyNvim {
    [ComImport, Guid("DC1C5A9C-E88A-4DDE-A5A1-60F82A20AEF7")]
    internal class FileOpenDialogClass { }

    [ComImport, Guid("43826D1E-E718-42EE-BC55-A1E261C37BFE"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IShellItem {
        void BindToHandler(IntPtr bindContext, ref Guid handler, ref Guid iid, out IntPtr value);
        void GetParent(out IShellItem parent);
        void GetDisplayName(uint kind, out IntPtr name);
        void GetAttributes(uint mask, out uint attributes);
        void Compare(IShellItem other, uint hint, out int order);
    }

    [ComImport, Guid("D57C7288-D4AD-4768-BE02-9D969532D960"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    internal interface IFileOpenDialog {
        [PreserveSig] int Show(IntPtr owner);
        void SetFileTypes(uint count, IntPtr filters);
        void SetFileTypeIndex(uint index);
        void GetFileTypeIndex(out uint index);
        void Advise(IntPtr events, out uint cookie);
        void Unadvise(uint cookie);
        void SetOptions(uint options);
        void GetOptions(out uint options);
        void SetDefaultFolder(IShellItem folder);
        void SetFolder(IShellItem folder);
        void GetFolder(out IShellItem folder);
        void GetCurrentSelection(out IShellItem item);
        void SetFileName([MarshalAs(UnmanagedType.LPWStr)] string name);
        void GetFileName(out IntPtr name);
        void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
        void SetOkButtonLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void SetFileNameLabel([MarshalAs(UnmanagedType.LPWStr)] string label);
        void GetResult(out IShellItem item);
        void AddPlace(IShellItem item, uint location);
        void SetDefaultExtension([MarshalAs(UnmanagedType.LPWStr)] string extension);
        void Close(int result);
        void SetClientGuid(ref Guid guid);
        void ClearClientData();
        void SetFilter(IntPtr filter);
        void GetResults(out IntPtr items);
        void GetSelectedItems(out IntPtr items);
    }

    public static class NativeDialog {
        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        private static extern void SHCreateItemFromParsingName(string path, IntPtr bindContext, ref Guid iid, out IShellItem item);
        [DllImport("user32.dll")]
        private static extern IntPtr GetForegroundWindow();

        // A null result means the user cancelled. Errors retain their HRESULT.
        public static string Choose(bool folder, string initialDirectory) {
            IFileOpenDialog dialog = null;
            IShellItem result = null;
            IShellItem initial = null;
            IntPtr displayName = IntPtr.Zero;
            try {
                dialog = (IFileOpenDialog)new FileOpenDialogClass();
                uint options;
                dialog.GetOptions(out options);
                // NOCHANGEDIR | FORCEFILESYSTEM | PATHMUSTEXIST.
                options |= 0x8u | 0x40u | 0x800u;
                options &= ~0x200u; // Disable multiselect.
                if (folder) options |= 0x20u;
                else options |= 0x1000u; // FILEMUSTEXIST.
                dialog.SetOptions(options);
                dialog.SetTitle(folder ? "Open project folder" : "Open file");
                if (!String.IsNullOrEmpty(initialDirectory) && System.IO.Directory.Exists(initialDirectory)) {
                    Guid shellItemId = typeof(IShellItem).GUID;
                    SHCreateItemFromParsingName(initialDirectory, IntPtr.Zero, ref shellItemId, out initial);
                    dialog.SetFolder(initial);
                }
                int hr = dialog.Show(GetForegroundWindow());
                if (hr == unchecked((int)0x800704C7)) return null;
                if (hr < 0) Marshal.ThrowExceptionForHR(hr);
                dialog.GetResult(out result);
                result.GetDisplayName(0x80058000u, out displayName); // SIGDN_FILESYSPATH.
                return Marshal.PtrToStringUni(displayName);
            } finally {
                if (displayName != IntPtr.Zero) Marshal.FreeCoTaskMem(displayName);
                if (result != null) Marshal.FinalReleaseComObject(result);
                if (initial != null) Marshal.FinalReleaseComObject(initial);
                if (dialog != null) Marshal.FinalReleaseComObject(dialog);
            }
        }
    }
}
"@
    Add-Type -TypeDefinition $nativeCode -Language CSharp
    # Compile the interop declarations without displaying a dialog for validation.
    if ($ValidateOnly) { Write-Response @{ validated = $true }; exit 0 }
    $selected = [MyNvim.NativeDialog]::Choose(($Mode -eq 'folder'), $InitialDirectory)
    if ($null -eq $selected) { Write-Response @{ cancelled = $true } }
    else { Write-Response @{ path = $selected } }
    exit 0
} catch {
    Write-Response @{ error = $_.Exception.Message }
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}