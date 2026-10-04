#ifndef CDISKERSCAN_H
#define CDISKERSCAN_H

#include <stddef.h>
#include <stdint.h>

typedef struct {
    int64_t seconds;
    int32_t nanoseconds;
} disker_timestamp_t;

typedef struct {
    uint64_t device;
    uint64_t inode;
    uint64_t logical_bytes;
    uint64_t allocated_bytes;
    uint32_t link_count;
    uint32_t mode;
    uint32_t owner_id;
    uint32_t group_id;
    uint32_t flags;
    disker_timestamp_t birth_time;
    disker_timestamp_t modification_time;
    disker_timestamp_t change_time;
    disker_timestamp_t access_time;
} disker_metadata_t;

typedef struct {
    const uint8_t *name;
    uint32_t name_length;
    uint32_t error_code;
    uint32_t mount_status;
    disker_metadata_t metadata;
} disker_entry_t;

int disker_read_directory(int descriptor, void *buffer, size_t buffer_size);
int disker_decode_entry(const void *buffer, size_t buffer_size, size_t *cursor, disker_entry_t *entry);
int disker_metadata_for_descriptor(int descriptor, disker_metadata_t *metadata);
int disker_open_directory(const char *path);
int disker_open_directory_relative(int root_descriptor, const char *path);

#endif
