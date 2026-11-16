/* Copyright © 2007-2009, The Sequential Project
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:
    * Redistributions of source code must retain the above copyright
      notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above copyright
      notice, this list of conditions and the following disclaimer in the
      documentation and/or other materials provided with the distribution.
    * Neither the name of the the Sequential Project nor the
      names of its contributors may be used to endorse or promote products
      derived from this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE SEQUENTIAL PROJECT ''AS IS'' AND ANY
EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE SEQUENTIAL PROJECT BE LIABLE FOR ANY
DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE. */

#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import <sys/stat.h>
#import <fcntl.h>

#pragma clang diagnostic push
	//	recent XADMaster sources have EOF and sign comparison issues
	//	just disable the warnings
	#pragma clang diagnostic ignored "-Wnewline-eof"
	#pragma clang diagnostic ignored "-Wsign-compare"
	#import "PGArchiveAdapter.h"
#pragma clang diagnostic pop

// Models
#import "PGDocument.h"
#import "PGNode.h"
#import "PGResourceIdentifier.h"
#import "PGDataProvider.h"

// Controllers
#import "PGDocumentController.h"
#import "PGDisplayController.h"

// Other Sources
#import "PGFoundationAdditions.h"

@interface PGDataProvider(PGArchiveDataProvider)

- (XADArchive *)archive;
- (int)entry;

@end

@interface PGArchiveDataProvider : PGDataProvider
{
	@private
	XADArchive *_archive;
	int _entry;

	//	The use of @synchronized(_archive) causes contention
	//	between all threads attempting to use _archive; when
	//	the main thread is attempting to draw thumbnails, this
	//	contention blocks the main thread by preventing the
	//	access to the icon (typeCode and extension) and data
	//	size (dataByteSize) values; to avoid this contention,
	//	these small metadata values are cached.
	OSType _typeCode;
	NSString *_extension;
	uint64_t _dataByteSize;
}

- (instancetype)initWithArchive:(XADArchive *)archive entry:(int)entry NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)setArchive:(XADArchive *)archive entry:(int)entry;	//	2026/11/16 added: the archive file was rewritten

@end

@interface PGArchiveFolderDataProvider : PGDataProvider

@end

static
BOOL
PG_entryIsInvisibleForName(NSString* name) {
	return [name characterAtIndex:0] == '.' ||
			NSNotFound != [name rangeOfString:@"/."].location;
}

@interface XADArchive(PGAdditions)

//- (BOOL)PG_entryIsInvisibleForName:(NSString *)name;
- (NSString *)PG_commonRootPath;
- (OSType)PG_OSTypeForEntry:(int)entry;

@end

/* static
NSString*
StringAtDepth(NSInteger depth) {
	return [@"\t\t\t\t\t" substringToIndex:depth];
} */

//	MARK: -

#if __has_feature(objc_arc)

@interface PGArchiveAdapter()

@property (nonatomic, strong) XADArchive *archive;
@property (nonatomic, assign) BOOL needsPassword;
@property (nonatomic, strong) PGNode *currentSubnode;
@property (nonatomic, assign) BOOL addedLoadingThumbnail;	//	2026/10/28 added
@property (nonatomic, assign) BOOL deferred;	//	2026/10/28 added: not loaded with its folder
@property (nonatomic, assign) BOOL triedDeferredThumbnail;	//	2026/10/28 added
@property (nonatomic, strong) NSMutableArray<PGNode *> *pendingRemovals;	//	2026/11/16 added
@property (nonatomic, assign) BOOL removalScheduled;	//	2026/11/16 added

- (void)_threaded_setError:(NSError *)error forNode:(PGNode *)node;
- (void)_updateThumbnailsOfChildren;

@end

#else

@interface PGArchiveAdapter(Private)

- (void)_threaded_setError:(NSError *)error forNode:(PGNode *)node;
- (void)_updateThumbnailsOfChildren;

@end

#endif

//	2026/10/28 added: limits for extracting an archive entry into memory
static off_t const PGArchiveEntryMaximumByteSize = 512ll << 20;
static off_t const PGArchiveEntryMaximumThumbnailByteSize = 64ll << 20;

@interface PGResourceAdapter(PGArchiveAdapterThumbnail)
- (void)_setRealThumbnail:(NSImage *)anImage;
@end

//	2026/10/28 added: a thumbnail of the first image (by name) of an archive
//	that hasn't been loaded, made on a background thread with an archive object
//	of its own so that the film strip doesn't wait for the archive to load
static NSImage *
PGThumbnailOfFirstImageInArchive(NSString *path, CGFloat maxPixelSize)
{
	XADArchive *const archive = [[XADArchive alloc] initWithFile:path delegate:nil error:NULL];
	if(!archive) return nil;
	int first = -1;
	NSString *firstName = nil;
	int const count = archive.numberOfEntries;
	for(int i = 0; i < count; i++) {
		NSString *const name = [archive nameOfEntry:i];
		if(!name.length || PG_entryIsInvisibleForName(name) || [archive entryIsDirectory:i] || [archive entryIsEncrypted:i]) continue;
		if([archive representativeSizeOfEntry:i] > PGArchiveEntryMaximumThumbnailByteSize) continue;
		if(![[UTType typeWithFilenameExtension:name.pathExtension] conformsToType:UTTypeImage]) continue;
		if(!firstName || [name localizedStandardCompare:firstName] == NSOrderedAscending) {
			first = i;
			firstName = name;
		}
	}
	if(first < 0) return nil;
	NSData *const data = [archive contentsOfEntry:first];
	if(!data) return nil;
	CGImageSourceRef const source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
	if(!source) return nil;
	CGImageRef const thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)@{
		(id)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
		(id)kCGImageSourceCreateThumbnailWithTransform: @YES,
		(id)kCGImageSourceThumbnailMaxPixelSize: @(maxPixelSize)});
	CFRelease(source);
	if(!thumbnail) return nil;
	NSImage *const image = [[NSImage alloc] initWithCGImage:thumbnail size:NSZeroSize];
	CGImageRelease(thumbnail);
	return image;
}


//	MARK: - 2026/11/16 added: removing entries from a zip file

//	XADMaster can't write archives, so this writes a copy of a zip file without
//	some of its entries: the local records of the other entries are copied as
//	they are (nothing is recompressed) and the central directory is written
//	again with the new offsets. The caller replaces the original file with the
//	copy, so a failure at any point leaves the original as it was. Anything
//	unusual (multi-disk archives, data after the central directory, etc) is
//	refused instead of guessed at

typedef struct {
	size_t record;	//	of the central directory record, in the directory
	size_t recordLength;
	size_t nameLength;
	size_t offsetField;	//	of the 64-bit local header offset, in the directory (0 if it's 32-bit)
	off_t localOffset;
	off_t end;	//	of the local record (the next one's offset)
	off_t newOffset;
	BOOL remove;
} PGZipEntry;

static uint16_t PGZipU16(uint8_t const *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t PGZipU32(uint8_t const *p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t PGZipU64(uint8_t const *p) { return (uint64_t)PGZipU32(p) | (uint64_t)PGZipU32(p + 4) << 32; }
static void PGZipPutU16(uint8_t *p, uint16_t v) { p[0] = (uint8_t)v; p[1] = (uint8_t)(v >> 8); }
static void PGZipPutU32(uint8_t *p, uint32_t v) { PGZipPutU16(p, (uint16_t)v); PGZipPutU16(p + 2, (uint16_t)(v >> 16)); }
static void PGZipPutU64(uint8_t *p, uint64_t v) { PGZipPutU32(p, (uint32_t)v); PGZipPutU32(p + 4, (uint32_t)(v >> 32)); }

static BOOL
PGZipRead(int fd, off_t offset, void *buffer, size_t length)
{
	while(length) {
		ssize_t const n = pread(fd, buffer, length, offset);
		if(n < 0 && EINTR == errno) continue;
		if(n <= 0) return NO;
		buffer = (uint8_t *)buffer + n;
		offset += n;
		length -= (size_t)n;
	}
	return YES;
}
static BOOL
PGZipWrite(int fd, void const *buffer, size_t length)
{
	while(length) {
		ssize_t const n = write(fd, buffer, length);
		if(n < 0 && EINTR == errno) continue;
		if(n <= 0) return NO;
		buffer = (uint8_t const *)buffer + n;
		length -= (size_t)n;
	}
	return YES;
}
static BOOL
PGZipCopy(int in, int out, off_t offset, off_t length, void *buffer, size_t bufferLength)
{
	while(length > 0) {
		size_t const n = (size_t)MIN(length, (off_t)bufferLength);
		if(!PGZipRead(in, offset, buffer, n) || !PGZipWrite(out, buffer, n)) return NO;
		offset += n;
		length -= n;
	}
	return YES;
}

//	dataOffsets: where the data of each entry to remove starts in the file
//	(XADDataOffsetKey); the AppleDouble file of a removed entry (__MACOSX/._name)
//	is removed with it. removedBytes gets the byte ranges that were left out
static BOOL
PGZipWriteCopyRemovingEntries(NSString *sourcePath, NSString *destinationPath, NSIndexSet *dataOffsets, NSMutableIndexSet *removedBytes)
{
	enum { PGZipBufferLength = 1 << 20 };
	BOOL ok = NO;
	int const in = open(sourcePath.fileSystemRepresentation, O_RDONLY | O_CLOEXEC);
	if(in < 0) return NO;
	int out = -1;
	uint8_t *tail = NULL, *cd = NULL, *z64 = NULL, *buffer = NULL;
	PGZipEntry *entries = NULL;
	size_t *sorted = NULL;
	do {
		struct stat st;
		if(fstat(in, &st) || st.st_size < 22) break;
		off_t const size = st.st_size;

		//	the end of central directory record
		size_t const tailLength = (size_t)MIN(size, (off_t)(22 + 0xFFFF));
		tail = malloc(tailLength);
		if(!tail || !PGZipRead(in, size - (off_t)tailLength, tail, tailLength)) break;
		ssize_t e = -1;
		for(ssize_t i = (ssize_t)tailLength - 22; i >= 0; i--) {
			if(PGZipU32(tail + i) != 0x06054b50 || (size_t)i + 22 + PGZipU16(tail + i + 20) != tailLength) continue;
			e = i;
			break;
		}
		if(e < 0) break;
		uint8_t *const eocd = tail + e;
		size_t const eocdLength = tailLength - (size_t)e;
		off_t const eocdOffset = size - (off_t)eocdLength;
		if(PGZipU16(eocd + 4) || PGZipU16(eocd + 6)) break;	//	more than one disk
		uint64_t count = PGZipU16(eocd + 10), cdSize = PGZipU32(eocd + 12), cdOffset = PGZipU32(eocd + 16);
		if(PGZipU16(eocd + 8) != count) break;
		off_t cdEnd = eocdOffset;

		//	Zip64
		uint8_t locator[20];
		size_t z64Length = 0;
		BOOL const isZip64 = eocdOffset >= 20 && PGZipRead(in, eocdOffset - 20, locator, sizeof(locator)) && 0x07064b50 == PGZipU32(locator);
		if(isZip64) {
			uint64_t const z64Offset = PGZipU64(locator + 8);
			uint8_t head[56];
			if(z64Offset > (uint64_t)eocdOffset || z64Offset + 56 > (uint64_t)eocdOffset - 20) break;
			if(!PGZipRead(in, (off_t)z64Offset, head, sizeof(head)) || PGZipU32(head) != 0x06064b50) break;
			uint64_t const length = PGZipU64(head + 4) + 12;
			if(length < 56 || length > (1 << 20) || z64Offset + length != (uint64_t)eocdOffset - 20) break;
			z64Length = (size_t)length;
			z64 = malloc(z64Length);
			if(!z64 || !PGZipRead(in, (off_t)z64Offset, z64, z64Length)) break;
			if(PGZipU32(z64 + 16) || PGZipU32(z64 + 20)) break;
			count = PGZipU64(z64 + 32);
			if(PGZipU64(z64 + 24) != count) break;
			cdSize = PGZipU64(z64 + 40);
			cdOffset = PGZipU64(z64 + 48);
			cdEnd = (off_t)z64Offset;
		}
		if(cdSize > (1u << 30) || cdOffset > (uint64_t)cdEnd || cdOffset + cdSize != (uint64_t)cdEnd || count > cdSize / 46) break;

		//	the central directory
		cd = malloc((size_t)cdSize ?: 1);
		if(!cd || !PGZipRead(in, (off_t)cdOffset, cd, (size_t)cdSize)) break;
		entries = calloc((size_t)count ?: 1, sizeof(PGZipEntry));
		sorted = calloc((size_t)count ?: 1, sizeof(size_t));
		if(!entries || !sorted) break;
		size_t p = 0;
		uint64_t n = 0;
		for(; n < count; n++) {
			if(p + 46 > cdSize || PGZipU32(cd + p) != 0x02014b50) break;
			size_t const nameLength = PGZipU16(cd + p + 28), extraLength = PGZipU16(cd + p + 30), commentLength = PGZipU16(cd + p + 32);
			size_t const length = 46 + nameLength + extraLength + commentLength;
			if(p + length > cdSize) break;
			PGZipEntry *const entry = entries + n;
			entry->record = p;
			entry->recordLength = length;
			entry->nameLength = nameLength;
			uint64_t offset = PGZipU32(cd + p + 42);
			if(0xFFFFFFFF == offset) {
				//	it's in the Zip64 extra field, after the sizes that are there too
				BOOL found = NO;
				size_t x = p + 46 + nameLength;
				size_t const extraEnd = x + extraLength;
				while(x + 4 <= extraEnd) {
					size_t const fieldLength = PGZipU16(cd + x + 2);
					if(x + 4 + fieldLength > extraEnd) break;
					if(1 == PGZipU16(cd + x)) {
						size_t q = x + 4;
						if(0xFFFFFFFF == PGZipU32(cd + p + 24)) q += 8;
						if(0xFFFFFFFF == PGZipU32(cd + p + 20)) q += 8;
						if(q + 8 <= x + 4 + fieldLength) {
							offset = PGZipU64(cd + q);
							entry->offsetField = q;
							found = YES;
						}
						break;
					}
					x += 4 + fieldLength;
				}
				if(!found) break;
			}
			if(offset >= cdOffset) break;
			entry->localOffset = (off_t)offset;
			sorted[n] = (size_t)n;
			p += length;
		}
		if(n != count || p != cdSize) break;

		//	a local record is taken to end where the next one starts, so that
		//	its length doesn't depend on its data descriptor, etc
		PGZipEntry *const sortEntries = entries;
		qsort_b(sorted, (size_t)count, sizeof(size_t), ^int(void const *a, void const *b) {
			off_t const x = sortEntries[*(size_t const *)a].localOffset, y = sortEntries[*(size_t const *)b].localOffset;
			return x < y ? -1 : x > y;
		});
		BOOL valid = YES;
		for(size_t k = 0; k < count; k++) {
			PGZipEntry *const entry = entries + sorted[k];
			entry->end = k + 1 < count ? entries[sorted[k + 1]].localOffset : (off_t)cdOffset;
			if(entry->end <= entry->localOffset) valid = NO;
		}
		if(!valid) break;

		//	the entries to remove
		for(NSUInteger d = dataOffsets.firstIndex; valid && NSNotFound != d; d = [dataOffsets indexGreaterThanIndex:d]) {
			PGZipEntry *found = NULL;
			for(size_t k = (size_t)count; k-- > 0;) {
				if((uint64_t)entries[sorted[k]].localOffset >= d) continue;
				found = entries + sorted[k];
				break;
			}
			uint8_t header[30];
			if(!found || !PGZipRead(in, found->localOffset, header, sizeof(header)) || PGZipU32(header) != 0x04034b50 ||
			   (uint64_t)found->localOffset + 30 + PGZipU16(header + 26) + PGZipU16(header + 28) != d) {
				valid = NO;
				break;
			}
			found->remove = YES;
			uint8_t const *const name = cd + found->record + 46;
			size_t const nameLength = found->nameLength;
			static char const prefix[] = "__MACOSX/";
			size_t const prefixLength = sizeof(prefix) - 1;
			if(nameLength >= prefixLength && !memcmp(name, prefix, prefixLength)) continue;
			size_t directoryLength = nameLength;
			while(directoryLength && name[directoryLength - 1] != '/') directoryLength--;
			NSMutableData *const partner = [NSMutableData dataWithBytes:prefix length:prefixLength];
			[partner appendBytes:name length:directoryLength];
			[partner appendBytes:"._" length:2];
			[partner appendBytes:name + directoryLength length:nameLength - directoryLength];
			for(size_t k = 0; k < count; k++) {
				if(entries[k].nameLength == partner.length && !memcmp(cd + entries[k].record + 46, partner.bytes, partner.length)) entries[k].remove = YES;
			}
		}
		if(!valid) break;

		//	the local records
		out = open(destinationPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, st.st_mode & 0777);
		buffer = malloc(PGZipBufferLength);
		if(out < 0 || !buffer) break;
		off_t outOffset = 0, runStart = 0, runEnd = count ? entries[sorted[0]].localOffset : (off_t)cdOffset;
		uint64_t newCount = 0;
		for(size_t k = 0; valid && k < count; k++) {
			PGZipEntry *const entry = entries + sorted[k];
			if(entry->remove) {
				valid = PGZipCopy(in, out, runStart, runEnd - runStart, buffer, PGZipBufferLength);
				outOffset += runEnd - runStart;
				runStart = runEnd = entry->end;
				[removedBytes addIndexesInRange:NSMakeRange((NSUInteger)entry->localOffset, (NSUInteger)(entry->end - entry->localOffset))];
			} else {
				entry->newOffset = outOffset + (entry->localOffset - runStart);
				runEnd = entry->end;
				newCount++;
			}
		}
		if(!valid || !PGZipCopy(in, out, runStart, runEnd - runStart, buffer, PGZipBufferLength)) break;
		outOffset += runEnd - runStart;

		//	the central directory
		NSMutableData *const newCD = [NSMutableData data];
		for(size_t k = 0; k < count; k++) {
			PGZipEntry const *const entry = entries + k;
			if(entry->remove) continue;
			NSUInteger const start = newCD.length;
			[newCD appendBytes:cd + entry->record length:entry->recordLength];
			uint8_t *const record = (uint8_t *)newCD.mutableBytes + start;
			if(entry->offsetField) PGZipPutU64(record + (entry->offsetField - entry->record), (uint64_t)entry->newOffset);
			else PGZipPutU32(record + 42, (uint32_t)entry->newOffset);	//	never more than it was
		}
		uint64_t const newCDOffset = (uint64_t)outOffset, newCDSize = newCD.length;
		if(!PGZipWrite(out, newCD.bytes, newCD.length)) break;
		if(isZip64) {
			PGZipPutU64(z64 + 24, newCount);
			PGZipPutU64(z64 + 32, newCount);
			PGZipPutU64(z64 + 40, newCDSize);
			PGZipPutU64(z64 + 48, newCDOffset);
			PGZipPutU64(locator + 8, newCDOffset + newCDSize);
			if(!PGZipWrite(out, z64, z64Length) || !PGZipWrite(out, locator, sizeof(locator))) break;
		}
		//	with Zip64, a field that says to use the Zip64 one stays that way
		if(!isZip64 || PGZipU16(eocd + 8) != 0xFFFF) PGZipPutU16(eocd + 8, (uint16_t)newCount);
		if(!isZip64 || PGZipU16(eocd + 10) != 0xFFFF) PGZipPutU16(eocd + 10, (uint16_t)newCount);
		if(!isZip64 || PGZipU32(eocd + 12) != 0xFFFFFFFF) PGZipPutU32(eocd + 12, (uint32_t)newCDSize);
		if(!isZip64 || PGZipU32(eocd + 16) != 0xFFFFFFFF) PGZipPutU32(eocd + 16, (uint32_t)newCDOffset);
		if(!PGZipWrite(out, eocd, eocdLength)) break;
		if(fsync(out)) break;
		ok = YES;
	} while(0);
	free(tail);
	free(cd);
	free(z64);
	free(buffer);
	free(entries);
	free(sorted);
	close(in);
	if(out >= 0) {
		if(close(out)) ok = NO;
		if(!ok) unlink(destinationPath.fileSystemRepresentation);
	}
	return ok;
}

@implementation PGArchiveAdapter

//	MARK: - 2026/10/28 added: archives are loaded when they're needed

- (BOOL)shouldRecursivelyCreateChildren
{
	//	archive files in a folder aren't loaded with it: opening one on a
	//	network volume costs a round trip per entry (RAR headers are spread over
	//	the file), which made up most of the time to open folders of archives;
	//	they're loaded when a page is needed (-loadDeferredChildrenIfAllowed),
	//	when they're clicked in the film strip, or for a bookmark in them.
	//	Archives in archives are in memory already and are loaded as before
	PGDataProvider *const dataProvider = self.dataProvider;
	if(self.parentAdapter && !dataProvider.archive && dataProvider.identifier.isFileIdentifier &&
	   self.node != [PGResourceAdapter nodeReloadingIgnoringMaxDepth]) {
		_deferred = YES;
		self.document.hasDeferredArchives = YES;
		return NO;
	}
	return [super shouldRecursivelyCreateChildren];
}
- (void)_loadDeferredArchive
{
	_deferred = NO;
	PGDocumentController *const dc = [PGDocumentController sharedDocumentController];
	[dc beginLoadingProgressWithName:self.node.identifier.displayName];
	[PGResourceAdapter reloadNodeIgnoringMaxDepth:self.node];	//	replaces this adapter
	[dc endLoadingProgress];
}
- (BOOL)loadDeferredChildrenIfAllowed
{
	if(!_deferred || ![PGResourceAdapter loadsDeferredContainerOfNode:self.node]) return NO;	//	2026/11/02 was +loadsDeferredContainers
	[self _loadDeferredArchive];
	return YES;
}
- (PGNode *)nodeForIdentifier:(PGResourceIdentifier *)ident
{
	//	eg, a bookmark of a page in the archive
	if(_deferred) for(PGResourceIdentifier *superident = ident.superidentifier; superident; superident = superident.superidentifier) {
		if(![self.node.identifier isEqual:superident]) continue;
		PGNode *const node = self.node;
		[self _loadDeferredArchive];
		return [node.resourceAdapter nodeForIdentifier:ident];
	}
	return [super nodeForIdentifier:ident];
}
- (void)generateThumbnailForContainer
{
	//	called by -thumbnail when there's no first page to take it from
	if(!_deferred || _triedDeferredThumbnail) return;
	_triedDeferredThumbnail = YES;
	NSString *const path = self.dataProvider.identifier.URL.path;
	if(!path) return;
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("PGArchiveAdapter.thumbnails", DISPATCH_QUEUE_SERIAL);
	});
	__weak PGArchiveAdapter *const weakSelf = self;
	dispatch_async(queue, ^{
		NSImage *image;
		@autoreleasepool {
			image = PGThumbnailOfFirstImageInArchive(path, 256.0f);
		}
		if(!image) return;
		dispatch_async(dispatch_get_main_queue(), ^{
			PGArchiveAdapter *const strongSelf = weakSelf;
			if(strongSelf && strongSelf.node.resourceAdapter == strongSelf) [strongSelf _setRealThumbnail:image];
		});
	});
}

//	MARK: - 2026/11/16 added: Move to Trash for the images in a zip file

//	The image is extracted into the Trash, and the zip file is replaced with a
//	copy that doesn't have it (see PGZipWriteCopyRemovingEntries()). Only for
//	zip files on disk: XADMaster can't write archives, and the other formats
//	aren't as simple to rewrite. This can't be undone with Edit > Undo
- (BOOL)_canRemoveEntries
{
	PGDataProvider *const dataProvider = self.dataProvider;
	if(_deferred || !_archive || dataProvider.archive) return NO;	//	not archives in archives
	PGResourceIdentifier *const ident = dataProvider.identifier;
	if(!ident.isFileIdentifier || !ident.URL) return NO;
	return [_archive.formatName isEqualToString:@"Zip"] && _archive.allFilenames.count <= 1;
}
+ (PGArchiveAdapter *)adapterForMovingNodeToTrash:(PGNode *)node
{
	XADArchive *const archive = [node.resourceAdapter.dataProvider archive];
	if(!archive) return nil;
	for(PGContainerAdapter *adapter = node.parentAdapter; adapter; adapter = adapter.parentAdapter) {
		if(![adapter isKindOfClass:[PGArchiveAdapter class]]) continue;
		PGArchiveAdapter *const archiveAdapter = (PGArchiveAdapter *)adapter;
		return archiveAdapter.archive == archive && [archiveAdapter _canRemoveEntries] ? archiveAdapter : nil;
	}
	return nil;
}
- (void)moveNodesToTrash:(NSArray<PGNode *> *)nodes
{
	NSAssert(NSThread.isMainThread, @"");
	if(!_pendingRemovals) _pendingRemovals = [NSMutableArray array];
	[_pendingRemovals addObjectsFromArray:nodes];
	//	replacing the file looks like its deletion to the document's subscription
	PGDocument *const document = self.document;
	if(document.node == self.node) document.replacedRootFilePath = self.dataProvider.identifier.URL.path;
	//	as for files, the nodes are removed first so that the next image is
	//	shown at once; if the archive can't be changed, it's loaded again
	for(PGNode *const node in nodes) [node removeFromDocument];
	if(_removalScheduled) return;	//	it takes all that are pending when it starts
	_removalScheduled = YES;
	static dispatch_queue_t queue;
	static dispatch_once_t once;
	dispatch_once(&once, ^{
		queue = dispatch_queue_create("PGArchiveAdapter.removals", DISPATCH_QUEUE_SERIAL);
	});
	dispatch_async(queue, ^{
		@autoreleasepool {
			[self _threaded_removePendingEntries];
		}
	});
}
- (void)_threaded_removePendingEntries
{
	NSMutableArray<PGDataProvider *> *const providers = [NSMutableArray array];
	__block PGResourceIdentifier *firstIdentifier = nil;
	__block XADArchive *archive = nil;
	__block NSString *path = nil;
	dispatch_sync(dispatch_get_main_queue(), ^{
		for(PGNode *const node in self.pendingRemovals) [providers addObject:node.resourceAdapter.dataProvider];
		firstIdentifier = self.pendingRemovals.firstObject.identifier;
		[self.pendingRemovals removeAllObjects];
		self.removalScheduled = NO;
		archive = self.archive;
		path = self.dataProvider.identifier.URL.path;
	});
	NSFileManager *const fileManager = [NSFileManager new];
	BOOL ok = providers.count && archive && path;

	NSMutableIndexSet *const dataOffsets = [NSMutableIndexSet indexSet];
	if(ok) for(PGDataProvider *const provider in providers) {
		NSNumber *const offset = provider.archive == archive ? [archive dataForkParserDictionaryForEntry:provider.entry][XADDataOffsetKey] : nil;
		if(!offset) {
			ok = NO;
			break;
		}
		[dataOffsets addIndex:offset.unsignedIntegerValue];
	}

	//	the new file is made on the volume of the archive, then the images are
	//	extracted into the Trash, and only then is the archive replaced
	NSURL *const archiveURL = path ? [NSURL fileURLWithPath:path] : nil;
	NSURL *const replacementDirectory = ok ? [fileManager URLForDirectory:NSItemReplacementDirectory inDomain:NSUserDomainMask appropriateForURL:archiveURL create:YES error:NULL] : nil;
	NSURL *const replacementURL = [replacementDirectory URLByAppendingPathComponent:archiveURL.lastPathComponent];
	NSMutableIndexSet *const removedBytes = [NSMutableIndexSet indexSet];
	ok = ok && replacementURL && PGZipWriteCopyRemovingEntries(path, replacementURL.path, dataOffsets, removedBytes);

	NSMutableArray<NSURL *> *const trashURLs = [NSMutableArray array];
	if(ok) for(PGDataProvider *const provider in providers) @autoreleasepool {
		NSString *const name = [archive nameOfEntry:provider.entry].lastPathComponent;
		NSData *const data = provider.data;	//	nil if it's encrypted, etc
		NSURL *const directory = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES] URLByAppendingPathComponent:[NSUUID UUID].UUIDString isDirectory:YES];
		NSURL *const URL = name.length ? [directory URLByAppendingPathComponent:name] : nil;
		NSURL *trashURL = nil;
		ok = data && URL && [fileManager createDirectoryAtURL:directory withIntermediateDirectories:YES attributes:nil error:NULL] &&
			[data writeToURL:URL atomically:NO] && [fileManager trashItemAtURL:URL resultingItemURL:&trashURL error:NULL];
		[fileManager removeItemAtURL:directory error:NULL];
		if(trashURL) [trashURLs addObject:trashURL];
		if(!ok) break;
	}

	BOOL const replaced = ok && [fileManager replaceItemAtURL:archiveURL withItemAtURL:replacementURL backupItemName:nil options:0 resultingItemURL:NULL error:NULL];
	if(replacementDirectory) [fileManager removeItemAtURL:replacementDirectory error:NULL];
	if(!replaced) for(NSURL *const URL in trashURLs) [fileManager removeItemAtURL:URL error:NULL];	//	they're still in the archive

	//	the archive object reads the old file, so it's opened again; an entry
	//	of the old one is found in the new one by where its data starts
	XADArchive *newArchive = nil;
	NSMutableDictionary<NSNumber *, NSNumber *> *const newEntries = [NSMutableDictionary dictionary];
	if(replaced) {
		newArchive = [[XADArchive alloc] initWithFile:path delegate:self error:NULL];
		int const count = newArchive.numberOfEntries;
		for(int i = 0; i < count; i++) {
			NSNumber *const offset = [newArchive dataForkParserDictionaryForEntry:i][XADDataOffsetKey];
			if(offset) newEntries[offset] = @(i);
		}
	}
	dispatch_sync(dispatch_get_main_queue(), ^{
		if(self.node.resourceAdapter != self) return;	//	eg, the document was closed
		NSMutableArray<void (^)(void)> *const changes = [NSMutableArray array];
		if(replaced && newArchive && self.archive == archive &&
		   [self _getChanges:changes forChildrenOf:self from:archive to:newArchive entries:newEntries removedBytes:removedBytes]) {
			for(void (^const change)(void) in changes) change();
			self.archive = newArchive;
			return;
		}
		//	the archive wasn't changed, so its images are shown again, or it was
		//	but the nodes can't be matched to it
		if(!replaced) NSBeep();
		PGDocument *const document = self.document;
		PGNode *const node = self.node;
		//	the nodes are replaced by loading the archive again; they're removed
		//	first so that none of them is the one that's shown meanwhile (see
		//	-[PGDisplayController documentWillRemoveNodes:])
		[self setUnsortedChildren:@[] presortedOrder:PGUnsorted];
		[PGResourceAdapter reloadNodeIgnoringMaxDepth:node];	//	replaces this adapter
		PGResourceAdapter *const adapter = node.resourceAdapter;
		PGNode *const restored = (replaced ? nil : [adapter nodeForIdentifier:firstIdentifier]) ?: [adapter sortedViewableNodeFirst:YES];
		if(restored) [document.displayController activateNode:restored];
	});
}
- (BOOL)_getChanges:(NSMutableArray<void (^)(void)> *)changes
        forChildrenOf:(PGContainerAdapter *)adapter
        from:(XADArchive *)oldArchive
        to:(XADArchive *)newArchive
        entries:(NSDictionary<NSNumber *, NSNumber *> *)newEntries
        removedBytes:(NSIndexSet *)removedBytes
{
	for(PGNode *const child in adapter.unsortedChildren) {
		PGResourceAdapter *const childAdapter = child.resourceAdapter;
		PGDataProvider *const provider = childAdapter.dataProvider;
		PGDisplayableIdentifier *const ident = child.identifier;
		NSInteger const i = ident.index;
		if(NSNotFound != i) {	//	not a folder that has no entry of its own
			if(i < 0 || i >= oldArchive.numberOfEntries) return NO;
			NSNumber *const offset = [oldArchive dataForkParserDictionaryForEntry:(int)i][XADDataOffsetKey];
			if(!offset) return NO;
			NSUInteger const oldOffset = offset.unsignedIntegerValue;
			NSNumber *const entry = newEntries[@(oldOffset - [removedBytes countOfIndexesInRange:NSMakeRange(0, oldOffset)])];
			if(!entry) return NO;
			[changes addObject:[^{
				//	the identifier too, so that a bookmark made from now on finds its page
				[ident setEntryIndex:entry.integerValue];
				if(provider.archive == oldArchive) [(PGArchiveDataProvider *)provider setArchive:newArchive entry:entry.intValue];
			} copy]];
		}
		//	an archive in the archive keeps reading the old file, which stays
		//	as it was for as long as it's open
		if(!childAdapter.isContainer || [childAdapter isKindOfClass:[PGArchiveAdapter class]]) continue;
		if(![self _getChanges:changes forChildrenOf:(PGContainerAdapter *)childAdapter from:oldArchive to:newArchive entries:newEntries removedBytes:removedBytes]) return NO;
	}
	return YES;
}

//	returns an array containing the child nodes which represent all objects
//	that are direct children of the given path
- (NSArray *)nodesUnderPath:(NSString *)path
			  parentAdapter:(PGContainerAdapter *)parent
		   remainingIndexes:(NSMutableIndexSet *)indexes
//					  depth:(NSInteger)depth	for debugging only
{
	NSParameterAssert(path);
	NSParameterAssert(parent);
	NSParameterAssert(_archive);
	NSMutableArray *const children = [NSMutableArray array];
	NSUInteger i = indexes.firstIndex;
	PGDocumentController *const dc = [PGDocumentController sharedDocumentController];	//	2026/10/28 added
	for(; NSNotFound != i; i = [indexes indexGreaterThanIndex:i]) {
		if(dc.loadingProgressStopped) break;
		@autoreleasepool {	//	REQUIRED otherwise the heap blows up (try it on a 50000 entry zip file)
			NSString *const entryPath = [_archive nameOfEntry:(int) i];
			if(!entryPath)
				continue;
			[dc noteLoadingProgressForPath:entryPath];
			//	at most one thumbnail per archive because extracting a late
			//	entry of a solid archive decompresses everything before it
			if(!_addedLoadingThumbnail && dc.loadingProgressWantsArchiveThumbnail &&	//	2026/10/28 was ...WantsThumbnail
			   ![_archive entryIsDirectory:(int) i] && ![_archive entryIsEncrypted:(int) i] &&
			   [_archive representativeSizeOfEntry:(int) i] <= PGArchiveEntryMaximumThumbnailByteSize &&
			   [[UTType typeWithFilenameExtension:entryPath.pathExtension] conformsToType:UTTypeImage]) {
				_addedLoadingThumbnail = YES;
				NSData *data;
				@synchronized(_archive) {
					data = [_archive contentsOfEntry:(int) i];
				}
				if(data) [dc addLoadingProgressThumbnailFromData:data];
			}

#if 1
			if(PG_entryIsInvisibleForName(entryPath))
				continue;
			if(path.length) {
				if(![entryPath hasPrefix:path])
					continue;
				
/*NSLog(@"%@comparing path[%lu] '%@' vs entryPath[%lu] '%@' --> %s",
	  StringAtDepth(depth),
	  path.length, [path substringFromIndex:194],
	  entryPath.length, [entryPath substringFromIndex:194],
	  path.length == entryPath.length ||
		  [entryPath characterAtIndex:path.length] != '/' ? "rej" : "acc");*/

				//	The entry in the archive for this parent-path
				//	should be removed to prevent the creation of
				//	duplicate nodes in the parent's node for this
				//	directory.
				//	Example: in archive /path/a.zip, the first entry
				//	is b/c.jpg and an entry for the directory b
				//	occurs later in the archive.
				//	When b/c.jpg is encountered, a node for 'b' is
				//	created and this fn is entered again (recursion)
				//	to get b's children. During this recursion for
				//	path 'b', the entry for the directory itself is
				//	removed from the indexes by this 'if' block, and
				//	no further processing of the entry for 'b' is done
				//	because its node will already exist (done by caller).
				//	If the b/c.jpg entry does not exist and in fact the
				//	directory has no child objects then this recursion
				//	to process b will only occur when b itself is
				//	encountered during its parent loop of the entries
				//	in the archive and the caller will remove b's entry
				//	from the indexes (it is never encountered during
				//	its recursion for b's children because there are no
				//	children).
				if(path.length == entryPath.length) {	//	special case
					[indexes removeIndex:i];
					continue;
				}

				//	when path is "/path/to/abc" and entryPath is "/path/to/abc.txt",
				//	abc.txt is NOT a node under path and must be ignored; the
				//	original code below does not test for this so it ended up
				//	processing ".txt" as a child node :(
				if([entryPath characterAtIndex:path.length] != '/')
					continue;
			}

			//	from here on, entryPath is definitely a node under path so it
			//	is now safe to remove index i from the index set (original
			//	code incorrectly removed entries first and then rejected them)
			[indexes removeIndex:i];
			NSString *const subpath = [path stringByAppendingPathComponent:
				[[entryPath substringFromIndex:path.length] PG_firstPathComponent]];
#else	//	original code:
			if([path length] && ![entryPath hasPrefix:path])
				continue;
			if([_archive PG_entryIsInvisibleForName:entryPath])
				continue;

			[indexes removeIndex:i];
			NSString *const subpath = [path stringByAppendingPathComponent:[[entryPath substringFromIndex:path.length] PG_firstPathComponent]];
			if(PGEqualObjects(path, entryPath))
				continue;
#endif

			BOOL const isEntrylessFolder = !PGEqualObjects(subpath, entryPath);
			BOOL const isFile = !isEntrylessFolder && ![_archive entryIsDirectory:(int) i];
//NSLog(@"%@\tsubpath '%@', isEntrylessFolder %u, isFile %u", StringAtDepth(depth),
//	  [subpath substringFromIndex:194], isEntrylessFolder, isFile);

			PGDisplayableIdentifier *const identifier =
				[self.node.identifier subidentifierWithIndex:isEntrylessFolder ? NSNotFound : i].displayableIdentifier;
			identifier.naturalDisplayName = subpath.lastPathComponent;
#if __has_feature(objc_arc)
			PGNode *const node = [[PGNode alloc] initWithParent:parent identifier:identifier];
#else
			PGNode *const node = [[[PGNode alloc] initWithParent:parent identifier:identifier] autorelease];
#endif
			if(isFile)
#if __has_feature(objc_arc)
				node.dataProvider = [[PGArchiveDataProvider alloc] initWithArchive:_archive entry:(int) i];
#else
				[node setDataProvider:[[[PGArchiveDataProvider alloc] initWithArchive:_archive entry:(int) i] autorelease]];
#endif
			else {
#if __has_feature(objc_arc)
				node.dataProvider = [PGArchiveFolderDataProvider new];
#else
				[node setDataProvider:[[[PGArchiveFolderDataProvider alloc] init] autorelease]];
#endif
				if(isEntrylessFolder) {
//NSLog(@"subpath '%@' entryPath '%@' isEntrylessFolder %u", subpath, entryPath, isEntrylessFolder);
//NSLog(@"isEntrylessFolder so adding index %lu backinto indexes", i);
					[indexes addIndex:i]; // We ended up taking care of a folder in its path instead.
				}
				PGContainerAdapter *const adapter = (PGContainerAdapter *)node.resourceAdapter;
//NSLog(@"%@\t>>> entering recursion to get children of subpath >>>", StringAtDepth(depth));
				[adapter setUnsortedChildren:[self nodesUnderPath:subpath
													parentAdapter:adapter
												 remainingIndexes:indexes]
				//											depth:depth+1]	for debugging only
							  presortedOrder:PGUnsorted];
//NSLog(@"%@\t<<< exiting recursion to get children of subpath <<<", StringAtDepth(depth));
			}
		//	[identifier setIcon:[[[node resourceAdapter] dataProvider] icon]];
			identifier.icon = (node.resourceAdapter.dataProvider).icon;
			if(node) {
//NSLog(@"%@\tpath '%@' is getting child @ subpath '%@'", StringAtDepth(depth),
//[path substringFromIndex:194], [subpath substringFromIndex:194]);
				[children addObject:node];
			}
		}	//	@autoreleasepool
	}	//	for
	return children;
}

/* for debugging only
- (NSArray *)nodesUnderPath:(NSString *)path
			  parentAdapter:(PGContainerAdapter *)parent
		   remainingIndexes:(NSMutableIndexSet *)indexes {
	return [self nodesUnderPath:path parentAdapter:parent remainingIndexes:indexes depth:0];
} */


//	MARK: - PGArchiveAdapter(Private)

- (void)_threaded_setError:(NSError *)error forNode:(PGNode *)node;
{
	// TODO: Figure this out...
//	[node performSelectorOnMainThread:@selector(setError:) withObject:error waitUntilDone:YES];
}
- (void)_updateThumbnailsOfChildren
{
	[self.document noteNodeThumbnailDidChange:self.node recursively:YES];
}

//	MARK: - PGContainerAdapter

- (PGRecursionPolicy)descendantRecursionPolicy
{
	return PGRecurseToAnyDepth;
}

//	MARK: - PGResourceAdapter

- (BOOL)canSaveData
{
	return YES;
}

//	MARK: -

- (void)load
{
	if(!_archive) {
		XADError error = XADNoError;
		PGDataProvider *const dataProvider = self.dataProvider;
		PGResourceIdentifier *const ident = dataProvider.identifier;
		[[PGDocumentController sharedDocumentController] noteLoadingProgressForPath:ident.URL.path];	//	2026/10/28 added
		if([dataProvider archive]) @synchronized([dataProvider archive]) {
			_archive = [[XADArchive alloc] initWithArchive:[dataProvider archive]
													 entry:[dataProvider entry]
												  delegate:self
													 error:&error];
		} else if(ident.isFileIdentifier)
			_archive = [[XADArchive alloc] initWithFile:ident.URL.path
											   delegate:self
												  error:&error]; // -data will return data for file URLs, but it's worth using -[XADArchive initWithFile:...].
		else {
			NSData *const data = self.data;
			if(data)
				_archive = [[XADArchive alloc] initWithData:data
												   delegate:self
													  error:&error];
		}
		if(!_archive || error != XADNoError || [_archive isCorrupted])
			return [self.node fallbackFromFailedAdapter:self]; // TODO: Return an appropriate error.
	}
	NSMutableIndexSet* indexSet = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, _archive.numberOfEntries)];
	NSArray *const children = [self nodesUnderPath:[_archive PG_commonRootPath]
									 parentAdapter:self
								  remainingIndexes:indexSet];
	[self setUnsortedChildren:children presortedOrder:PGUnsorted];
	[self.node loadFinishedForAdapter:self];
}

//	MARK: - NSObject

#if !__has_feature(objc_arc)
- (void)dealloc
{
	@synchronized(_archive) {
		[_archive release];
		_archive = nil;
	}
	[super dealloc];
}
#endif

//	MARK: - NSObject(XADArchiveDelegate)

- (void)archiveNeedsPassword:(XADArchive *)archive
{
	_needsPassword = YES;
	[self _threaded_setError:[NSError errorWithDomain:PGNodeErrorDomain code:PGPasswordError userInfo:nil] forNode:_currentSubnode];
}
-(NSStringEncoding)archive:(XADArchive *)archive encodingForData:(NSData *)data guess:(NSStringEncoding)guess confidence:(float)confidence
{
	return guess;
}

//MARK: - <PGNodeDataSource>
//
//- (NSDictionary *)fileAttributesForNode:(PGNode *)node
//{
//	NSUInteger const i = [[node identifier] index];
//	if(NSNotFound == i) return nil;
//	NSMutableDictionary *const attributes = [NSMutableDictionary dictionary];
//	[attributes PG_setObject:[[_archive attributesOfEntry:i] objectForKey:XADCreationDateKey] forKey:NSFileCreationDate];
//	if(![_archive entryIsDirectory:i]) [attributes setObject:[NSNumber numberWithUnsignedLongLong:[_archive representativeSizeOfEntry:i]] forKey:NSFileSize];
//	return attributes;
//}
//- (void)node:(PGNode *)sender willLoadWithInfo:(NSMutableDictionary *)info
//{
//	NSUInteger const i = [[sender identifier] index];
//	if(NSNotFound == i) return;
//	if([_archive entryIsArchive:i]) [info setObject:[NSNumber numberWithBool:YES] forKey:PGKnownToBeArchiveKey];
//	if(![info objectForKey:PGOSTypeKey]) [info PG_setObject:[_archive PG_OSTypeForEntry:i standardFormat:NO] forKey:PGOSTypeKey];
//	if(![info objectForKey:PGExtensionKey]) [info PG_setObject:[[_archive nameOfEntry:i] pathExtension] forKey:PGExtensionKey];
//}
//- (BOOL)node:(PGNode *)sender getData:(out NSData **)outData info:(NSDictionary *)info fast:(BOOL)flag
//{
//	NSUInteger const i = [[sender identifier] index];
//	if(NSNotFound == i || flag || [_archive entryIsDirectory:i]) {
//		if(outData) *outData = nil;
//		return YES;
//	}
//	NSData *data = nil;
//	@synchronized(_archive) {
//		NSString *const pass = [info objectForKey:PGPasswordKey];
//		if(pass) [_archive setPassword:pass];
//		BOOL const neededPassword = _needsPassword;
//		_needsPassword = NO;
//		_currentSubnode = sender;
//		[_archive clearLastError];
//		data = [_archive contentsOfEntry:i];
//		switch([_archive lastError]) {
//			case XADNoError:
//			case XADPasswordError: 
//				if(!_needsPassword) [self archiveNeedsPassword:_archive];
//				break;
//			default:
//				[self _threaded_setError:[NSError PG_errorWithDomain:PGNodeErrorDomain code:PGGenericError localizedDescription:[NSString stringWithFormat:NSLocalizedString(@"The error “%@” occurred while parsing the archive.", @"XADMaster error reporting. %@ is replaced with the XADMaster error."), [_archive describeLastError]] userInfo:nil] forNode:_currentSubnode];
//				break;
//		}
//		_currentSubnode = nil;
//		if(neededPassword && !_needsPassword) [[PGArchiveAdapter PG_performOn:self allowOnce:YES withStorage:PGArchiveAdapterList] performSelectorOnMainThread:@selector(_updateThumbnailsOfChildren) withObject:nil waitUntilDone:NO];
//	}
//	if(outData) *outData = data;
//	return YES;
//}

@end

//	MARK: -

@implementation PGDataProvider(PGArchiveDataProvider)

- (XADArchive *)archive
{
	return nil;
}
- (int)entry
{
	return 0;	//	2023/09/10 this should probably be -1 because 0 is a valid entry index
}

@end

//	MARK: -

@implementation PGArchiveDataProvider

- (instancetype)initWithArchive:(XADArchive *)archive entry:(int)entry;
{
	if((self = [super init])) {
		NSParameterAssert(nil != archive);
#if __has_feature(objc_arc)
		_archive = archive;
#else
		_archive = [archive retain];
#endif
		_entry = entry;

		_typeCode = [archive PG_OSTypeForEntry:entry];
#if __has_feature(objc_arc)
		_extension = [archive nameOfEntry:entry].pathExtension.lowercaseString;
#else
		_extension = [[[[archive nameOfEntry:entry] pathExtension] lowercaseString] retain];
#endif
		{
			off_t const value = [archive representativeSizeOfEntry:entry];
			//	2026/10/28 a malicious archive can claim a size which becomes negative
			//	here (eg, 2^64-1); this was an assertion, which crashed the app
			_dataByteSize = value > 0 ? (uint64_t) value : 0;
		}
	}
	return self;
}

//	MARK: PGDataProvider

- (NSData *)data
{
//NSLog(@"PGArchiveDataProvider -data for entry %d", _entry);
	//	2026/10/28 entries are extracted into memory, so refuse absurd sizes (eg,
	//	decompression bombs)
	if(_dataByteSize > PGArchiveEntryMaximumByteSize) return nil;
	XADArchive *const archive = self.archive;	//	2026/11/16 these can change (see -setArchive:entry:)
	int const entry = self.entry;
	@synchronized(archive) {
		return [archive contentsOfEntry:entry]; // TODO: Handle password issues.
	}
	return nil;
}
- (uint64_t)dataByteSize
{
	return _dataByteSize;
/*	@synchronized(_archive) {
		off_t const value = [_archive representativeSizeOfEntry:_entry];
		NSParameterAssert(value >= 0);	//	the following cast should be safe
		return (uint64_t) value;	//	cast signed 64-bit int to unsigned 64-bit int
	}
	return 0;	*/
}
- (NSDate *)dateModified
{	//	2023/09/17 added to implement sorting by date modified in archives
	XADArchive *const archive = self.archive;
	int const entry = self.entry;
	@synchronized(archive) {
		return [archive attributesOfEntry:entry][NSFileModificationDate];
	}
	return nil;
}
- (NSDate *)dateCreated
{
	XADArchive *const archive = self.archive;
	int const entry = self.entry;
	@synchronized(archive) {
		//	2023/09/18 bugfix: was using XADCreationDateKey instead of NSFileCreationDate
		return [archive attributesOfEntry:entry][NSFileCreationDate];
	}
	return nil;
}

//	MARK: -

- (OSType)typeCode
{
	return _typeCode;
/*	@synchronized(_archive) {
		return [_archive PG_OSTypeForEntry:_entry];
	}
	return 0;	*/
}
- (NSString *)extension
{
	return _extension;
/*	@synchronized(_archive) {
		return [[[_archive nameOfEntry:_entry] pathExtension] lowercaseString];
	}
	return nil;	*/
}

//	MARK: -

- (BOOL)hasData
{
	//	2023/09/10 [PGDataProvider hasData] invokes [self data] which is
	//	time-expensive when dealing with zip archives (and creates objects
	//	that have no purpose and will just get reclaimed by the autorelease
	//	pool). However, assuming that this instance is created to model an
	//	archive entry, then it should have data so avoid the need to create
	//	a NSData instance and just return YES.
	//	TODO: is it always correct to return true? Are there times when it should be NO?
	return YES;
}

- (NSData *)fourCCData
{
	return nil; // Too slow.
}
/* - (NSNumber *)dataLength
{	2023/09/17 deprecated
	@synchronized(_archive) {
		return [NSNumber numberWithLongLong:[_archive representativeSizeOfEntry:_entry]];
	}
	return nil;
} */

//	MARK: PGDataProvider(PGArchiveDataProvider)

//	2026/11/16 these are read on other threads (eg, for thumbnails), and are
//	changed when the archive file is rewritten
- (XADArchive *)archive
{
	@synchronized(self) {
		return _archive;
	}
}
- (int)entry
{
	@synchronized(self) {
		return _entry;
	}
}
- (void)setArchive:(XADArchive *)archive entry:(int)entry
{
	NSParameterAssert(archive);
	@synchronized(self) {
		_archive = archive;
		_entry = entry;
	}
}

//	MARK: PGDataProvider(PGResourceAdapterLoading)

- (NSArray *)adapterClassesForNode:(PGNode *)node
{
	XADArchive *const archive = self.archive;
	int const entry = self.entry;
	@synchronized(archive) {
		if([archive entryIsArchive:entry]) return @[[PGArchiveAdapter class]];
	}
	return [super adapterClassesForNode:node];
}

//	MARK: NSObject

#if !__has_feature(objc_arc)
- (void)dealloc
{
	[_extension release];
	[_archive release];
	[super dealloc];
}
#endif

@end

//	MARK: -
@implementation PGArchiveFolderDataProvider

//	MARK: PGDataProvider

- (NSString *)UTIType
{
	if (@available(macOS 11.0, *))
		return UTTypeFolder.identifier;
	else
		return (NSString *)kUTTypeFolder;
}
- (OSType)typeCode
{
	return 'fold';
}

//	MARK: - PGDataProvider(PGResourceAdapterLoading)

- (NSArray *)adapterClassesForNode:(PGNode *)node
{
	return @[[PGContainerAdapter class]];
}

@end

//	MARK: -

@implementation XADArchive(PGAdditions)

#if 0
//	parameter 'name' is actually a filesystem object's path
- (BOOL)PG_entryIsInvisibleForName:(NSString *)name
{
	if([name hasPrefix:@"."]) return YES;
	if(NSNotFound != [name rangeOfString:@"/."].location) return YES;
	return NO;
}
#endif

- (NSString *)PG_commonRootPath
{
	NSInteger i;
	NSString *root = nil;
	for(i = 0; i < [self numberOfEntries]; i++) {
		NSString *entryName = [self nameOfEntry:(int) i];
		if(PG_entryIsInvisibleForName(entryName))//if([self PG_entryIsInvisibleForName:entryName])
			continue;
		if(![self entryIsDirectory:(int) i]) entryName = entryName.stringByDeletingLastPathComponent;
		else if([entryName hasSuffix:@"/"]) entryName = [entryName substringToIndex:entryName.length - 1];
		if(!root) root = entryName;
		else while(!PGEqualObjects(root, entryName)) {
			if(root.length > entryName.length) root = root.stringByDeletingLastPathComponent;
			else entryName = entryName.stringByDeletingLastPathComponent;
		}
	}
	return root ? root : @"";
}
- (OSType)PG_OSTypeForEntry:(int)entry
{
	return [self entryIsDirectory:entry] ? 'fold' : [[self attributesOfEntry:entry][NSFileHFSTypeCode] unsignedIntValue];
}

@end
