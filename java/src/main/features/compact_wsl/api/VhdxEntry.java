package main.features.compact_wsl.api;

/** Info about a discovered VHDX file. */
public class VhdxEntry {
    public String distro;
    public String path;
    public long sizeBytes;
    /** Bytes used inside the ext4 filesystem (-1 if WSL query failed). */
    public long innerUsedBytes = -1;
    /** Bytes reclaimable by compaction (-1 if query failed). */
    public long reclaimableBytes = -1;
}
