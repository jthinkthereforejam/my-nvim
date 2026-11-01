on run argv
    set selectionMode to item 1 of argv
    set initialFolder to missing value
    if (count of argv) > 1 then
        try
            set initialFolder to (POSIX file (item 2 of argv)) as alias
        end try
    end if
    try
        if selectionMode is "folder" then
            if initialFolder is missing value then
                set selectedItem to choose folder with prompt "Open project folder"
            else
                set selectedItem to choose folder with prompt "Open project folder" default location initialFolder
            end if
        else
            if initialFolder is missing value then
                set selectedItem to choose file with prompt "Open file"
            else
                set selectedItem to choose file with prompt "Open file" default location initialFolder
            end if
        end if
        return POSIX path of selectedItem
    on error errorMessage number errorNumber
        if errorNumber is -128 then return ""
        error errorMessage number errorNumber
    end try
end run