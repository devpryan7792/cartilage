#!/usr/bin/env python3
import sys

def set_ntfs_dirty(img_path, dirty=True):
    with open(img_path, "r+b") as f:
        boot = f.read(512)
        bytes_per_sector = int.from_bytes(boot[11:13], "little")
        sectors_per_cluster = boot[13]
        cluster_size = bytes_per_sector * sectors_per_cluster
        mft_cluster = int.from_bytes(boot[48:56], "little")
        clusters_per_mft_record = int.from_bytes(boot[64:65], "little", signed=True)
        if clusters_per_mft_record < 0:
            mft_record_size = 1 << (-clusters_per_mft_record)
        else:
            mft_record_size = clusters_per_mft_record * cluster_size

        mft_mirr_cluster = int.from_bytes(boot[56:64], "little")
        mft_offsets = [mft_cluster * cluster_size]
        if mft_mirr_cluster > 0:
            mft_offsets.append(mft_mirr_cluster * cluster_size)

        for base_offset in mft_offsets:
            f.seek(base_offset + 3 * mft_record_size)  # Record 3: $Volume
            rec = f.read(mft_record_size)
            if rec[:4] != b"FILE":
                continue

            pos = int.from_bytes(rec[20:22], "little")
            while pos < len(rec):
                attr_type = int.from_bytes(rec[pos:pos+4], "little")
                if attr_type == 0xffffffff or attr_type == 0:
                    break
                attr_len = int.from_bytes(rec[pos+4:pos+8], "little")
                if attr_type == 0x70:  # $VOLUME_INFORMATION
                    val_offset = int.from_bytes(rec[pos+20:pos+22], "little")
                    val_pos = pos + val_offset
                    flags_offset = base_offset + 3 * mft_record_size + val_pos + 10
                    flags = int.from_bytes(rec[val_pos+10:val_pos+12], "little")
                    if dirty:
                        flags |= 0x0001
                    else:
                        flags &= ~0x0001
                    f.seek(flags_offset)
                    f.write(flags.to_bytes(2, "little"))
                    break
                pos += attr_len

if __name__ == "__main__":
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} <ntfs_image> [--clear]")
        sys.exit(1)
    is_dirty = True
    if len(sys.argv) > 2 and sys.argv[2] == "--clear":
        is_dirty = False
    set_ntfs_dirty(sys.argv[1], is_dirty)
