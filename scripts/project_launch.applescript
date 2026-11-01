-- All paths and Neovim arguments arrive as data, never AppleScript source.
on run argv
    if (count of argv) < 2 then error "Missing Neovim launcher arguments"
    set workingDirectory to item 1 of argv
    set nvimExecutable to item 2 of argv
    -- Terminal may already be running with its own environment. Clear these in
    -- the new shell command as well as in the osascript child environment.
    set commandText to "cd -- " & quoted form of workingDirectory & " && /usr/bin/env -u NVIM -u NVIM_LISTEN_ADDRESS -u NVIM_LOG_FILE -u NVIM_SERVERNAME -u SERVERNAME -u VIM -u VIMRUNTIME -u MYVIMRC -u VIMINIT -u EXINIT " & quoted form of nvimExecutable
    if (count of argv) > 2 then
        repeat with position from 3 to count of argv
            set commandText to commandText & " " & quoted form of (item position of argv)
        end repeat
    end if
    tell application id "com.apple.Terminal"
        do script commandText
        activate
    end tell
    return ""
end run