#include "CDiskerScan.h"
#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/vnode.h>
#include <unistd.h>

static const attrgroup_t common_attributes = ATTR_CMN_NAME | ATTR_CMN_DEVID |
    ATTR_CMN_OBJTYPE | ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_CHGTIME |
    ATTR_CMN_ACCTIME | ATTR_CMN_OWNERID | ATTR_CMN_GRPID | ATTR_CMN_ACCESSMASK |
    ATTR_CMN_FLAGS | ATTR_CMN_FILEID | ATTR_CMN_ERROR | ATTR_CMN_RETURNED_ATTRS;

int disker_read_directory(int descriptor, void *buffer, size_t buffer_size) {
    struct attrlist attributes = {0};
    attributes.bitmapcount = ATTR_BIT_MAP_COUNT;
    attributes.commonattr = common_attributes;
    attributes.dirattr = ATTR_DIR_LINKCOUNT | ATTR_DIR_MOUNTSTATUS;
    attributes.fileattr = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
    return getattrlistbulk(descriptor, &attributes, buffer, buffer_size, 0);
}

static int read_field(const uint8_t *record, size_t length, size_t *offset, void *result, size_t size) {
    if (*offset > length || size > length - *offset) {
        return EBADMSG;
    }
    memcpy(result, record + *offset, size);
    *offset += (size + 3) & ~(size_t)3;
    return 0;
}

static uint32_t mode_for_type(uint32_t type) {
    switch (type) {
        case VREG: return S_IFREG;
        case VDIR: return S_IFDIR;
        case VLNK: return S_IFLNK;
        case VSOCK: return S_IFSOCK;
        case VFIFO: return S_IFIFO;
        case VCHR: return S_IFCHR;
        case VBLK: return S_IFBLK;
        default: return 0;
    }
}

static disker_timestamp_t timestamp(struct timespec value) {
    return (disker_timestamp_t){ .seconds = value.tv_sec, .nanoseconds = (int32_t)value.tv_nsec };
}

int disker_decode_entry(const void *buffer, size_t buffer_size, size_t *cursor, disker_entry_t *entry) {
    if (*cursor > buffer_size || sizeof(uint32_t) > buffer_size - *cursor) {
        return EBADMSG;
    }
    const uint8_t *record = (const uint8_t *)buffer + *cursor;
    uint32_t length = 0;
    memcpy(&length, record, sizeof(length));
    if (length < sizeof(uint32_t) + sizeof(attribute_set_t) || length > buffer_size - *cursor) {
        return EBADMSG;
    }
    size_t offset = sizeof(uint32_t);
    attribute_set_t returned = {0};
    int error = read_field(record, length, &offset, &returned, sizeof(returned));
    if (error != 0) {
        return error;
    }
    memset(entry, 0, sizeof(*entry));
    *cursor += length;

#define READ_ATTRIBUTE(group, bit, destination) \
    do { \
        if (returned.group & (bit)) { \
            error = read_field(record, length, &offset, &(destination), sizeof(destination)); \
            if (error != 0) return error; \
        } \
    } while (0)

    READ_ATTRIBUTE(commonattr, ATTR_CMN_ERROR, entry->error_code);
    attrreference_t name_reference = {0};
    size_t name_offset = offset;
    READ_ATTRIBUTE(commonattr, ATTR_CMN_NAME, name_reference);
    if (!(returned.commonattr & ATTR_CMN_NAME) || name_reference.attr_dataoffset < 0 || name_reference.attr_length < 2) {
        return EBADMSG;
    }
    size_t name_start = name_offset + (size_t)name_reference.attr_dataoffset;
    if (name_start > length || name_reference.attr_length > length - name_start) {
        return EBADMSG;
    }
    const uint8_t *name = record + name_start;
    if (name[name_reference.attr_length - 1] != 0 || memchr(name, 0, name_reference.attr_length - 1) != NULL ||
        memchr(name, '/', name_reference.attr_length - 1) != NULL) {
        return EBADMSG;
    }
    entry->name = name;
    entry->name_length = name_reference.attr_length - 1;
    if (entry->error_code != 0) {
        return 0;
    }
    uint32_t device = 0;
    uint32_t type = 0;
    struct timespec birth = {0};
    struct timespec modification = {0};
    struct timespec change = {0};
    struct timespec access = {0};
    READ_ATTRIBUTE(commonattr, ATTR_CMN_DEVID, device);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_OBJTYPE, type);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_CRTIME, birth);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_MODTIME, modification);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_CHGTIME, change);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_ACCTIME, access);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_OWNERID, entry->metadata.owner_id);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_GRPID, entry->metadata.group_id);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_ACCESSMASK, entry->metadata.mode);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_FLAGS, entry->metadata.flags);
    READ_ATTRIBUTE(commonattr, ATTR_CMN_FILEID, entry->metadata.inode);
    entry->metadata.device = device;
    entry->metadata.mode = (entry->metadata.mode & ~S_IFMT) | mode_for_type(type);
    entry->metadata.birth_time = timestamp(birth);
    entry->metadata.modification_time = timestamp(modification);
    entry->metadata.change_time = timestamp(change);
    entry->metadata.access_time = timestamp(access);
    if (type == VDIR) {
        READ_ATTRIBUTE(dirattr, ATTR_DIR_LINKCOUNT, entry->metadata.link_count);
        READ_ATTRIBUTE(dirattr, ATTR_DIR_MOUNTSTATUS, entry->mount_status);
    } else {
        int64_t logical = 0;
        int64_t allocated = 0;
        READ_ATTRIBUTE(fileattr, ATTR_FILE_LINKCOUNT, entry->metadata.link_count);
        READ_ATTRIBUTE(fileattr, ATTR_FILE_TOTALSIZE, logical);
        READ_ATTRIBUTE(fileattr, ATTR_FILE_ALLOCSIZE, allocated);
        if (logical < 0 || allocated < 0) {
            return EBADMSG;
        }
        entry->metadata.logical_bytes = (uint64_t)logical;
        entry->metadata.allocated_bytes = (uint64_t)allocated;
        attrgroup_t required_file = ATTR_FILE_LINKCOUNT | ATTR_FILE_TOTALSIZE | ATTR_FILE_ALLOCSIZE;
        if ((returned.fileattr & required_file) != required_file) {
            entry->error_code = ENOTSUP;
        }
    }
    attrgroup_t required_common = common_attributes & ~(ATTR_CMN_ERROR | ATTR_CMN_RETURNED_ATTRS);
    if ((returned.commonattr & required_common) != required_common) {
        entry->error_code = ENOTSUP;
    }
#undef READ_ATTRIBUTE
    return 0;
}

int disker_metadata_for_descriptor(int descriptor, disker_metadata_t *metadata) {
    struct stat status = {0};
    if (fstat(descriptor, &status) != 0) {
        return errno;
    }
    memset(metadata, 0, sizeof(*metadata));
    metadata->device = (uint32_t)status.st_dev;
    metadata->inode = status.st_ino;
    metadata->link_count = status.st_nlink;
    metadata->mode = status.st_mode;
    metadata->owner_id = status.st_uid;
    metadata->group_id = status.st_gid;
    metadata->flags = status.st_flags;
    metadata->birth_time = timestamp(status.st_birthtimespec);
    metadata->modification_time = timestamp(status.st_mtimespec);
    metadata->change_time = timestamp(status.st_ctimespec);
    metadata->access_time = timestamp(status.st_atimespec);
    if (!S_ISDIR(status.st_mode)) {
        metadata->logical_bytes = status.st_size;
        metadata->allocated_bytes = (uint64_t)status.st_blocks * 512;
    }
    return 0;
}

int disker_open_directory(const char *path) {
    if (strlen(path) < PATH_MAX) {
        return open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC);
    }
    char *components = strdup(path + 1);
    if (components == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC);
    if (current < 0) {
        int error = errno;
        free(components);
        errno = error;
        return -1;
    }
    char *component = components;
    for (;;) {
        char *separator = strchr(component, '/');
        if (separator != NULL) {
            *separator = 0;
        }
        int options = O_RDONLY | O_DIRECTORY | O_CLOEXEC;
        if (separator == NULL) {
            options |= O_NOFOLLOW;
        }
        int next = openat(current, component, options);
        int error = errno;
        close(current);
        if (next < 0) {
            free(components);
            errno = error;
            return -1;
        }
        current = next;
        if (separator == NULL) {
            break;
        }
        component = separator + 1;
    }
    free(components);
    return current;
}

int disker_open_directory_relative(int root_descriptor, const char *path) {
    size_t length = strlen(path);
    if (length < PATH_MAX) {
        return openat(root_descriptor, length == 0 ? "." : path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
    }
    char *components = strdup(path);
    if (components == NULL) {
        errno = ENOMEM;
        return -1;
    }
    int current = dup(root_descriptor);
    if (current < 0) {
        int error = errno;
        free(components);
        errno = error;
        return -1;
    }
    char *component = components;
    for (;;) {
        char *separator = strchr(component, '/');
        if (separator != NULL) {
            *separator = 0;
        }
        int next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC);
        int error = errno;
        close(current);
        if (next < 0) {
            free(components);
            errno = error;
            return -1;
        }
        current = next;
        if (separator == NULL) {
            break;
        }
        component = separator + 1;
    }
    free(components);
    return current;
}
