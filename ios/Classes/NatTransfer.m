//
//  NatTransfer.m
//
//  Created by huangyake on 17/1/7.
//  Copyright © 2017 Nat. All rights reserved.
//

#import "NatTransfer.h"
#import <Photos/Photos.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <CommonCrypto/CommonDigest.h>
#import <CommonCrypto/CommonCryptor.h>
#import <MobileCoreServices/MobileCoreServices.h>


enum NatFileTransferDirection {
    Nat_TRANSFER_UPLOAD = 1,
    Nat_TRANSFER_DOWNLOAD = 2,
};
typedef int NatFileTransferDirection;


@interface NatTransfer ()
@property (nonatomic, strong) NSOperationQueue* queue;
@property (nonatomic, assign) NatFileTransferDirection transferTYpe;
@property (nonatomic, strong) NSString *targetPath;
@property (nonatomic, strong) NSMutableData* responseData;

@property (nonatomic, strong) NatCallback uploadback;
@property (nonatomic, strong) NatCallback downloadback;

@property (nonatomic, strong) NSFileHandle *targetFileHandle;
@property (nonatomic, assign) long long bytesTransfered;
@property (nonatomic, assign) long long bytesExpected;

@property (nonatomic, assign) int responseCode;

@property (nonatomic, strong) NSDictionary* responseHeaders;
@property (nonatomic, assign) NSUInteger dataLenth;

@property (nonatomic, strong) NSString *randomPath;
@property (nonatomic, strong) NSString *downfilename;
@end

@implementation NatTransfer

//+ (NatTransfer *)singletonManger{
//    static id manager = nil;
//    static dispatch_once_t onceToken;
//    dispatch_once(&onceToken, ^{
//        manager = [[self alloc] init];
//    });
//    return manager;
//}


- (void)download:(NSDictionary *)params :(NatCallback)callback{
    NSURL *url;
    NSString *target;
     NSDictionary *headers;
    self.targetFileHandle = nil;
    self.bytesTransfered = 0;
    self.bytesExpected = 0;
    if ([params isKindOfClass:[NSDictionary class]] && params[@"url"]) {
        url = [NSURL URLWithString:params[@"url"]];
        target = params[@"target"];
        headers = params[@"headers"];
        self.downfilename = params[@"name"];
    }else{
        callback(@{@"error":@{@"code":@152050,@"msg":@"DOWNLOAD_INVALID_ARGUMENT"}},nil);
        return;
    }
    
//    NSURL *url = [NSURL URLWithString:params[@"url"]];
    self.transferTYpe = Nat_TRANSFER_DOWNLOAD;
    self.downloadback = callback;
//
    
    
    NSURL* targetURL;
    if (!target ||[target hasPrefix:@"/"]) {
        target = [target stringByReplacingOccurrencesOfString:@"//" withString:@"/"];
        
        NSString*document =[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask,YES) firstObject];
        NSString*filePath = [document stringByAppendingPathComponent:target];
        filePath = [filePath stringByAppendingString:@"/nat/download"];
        
        self.randomPath = filePath;
        NSString *boundary = [self md5:[@"nattransferdownload" stringByAppendingFormat:@"%lf",[[NSDate date] timeIntervalSince1970]]];
        self.randomPath = [self.randomPath stringByAppendingFormat:@"/%@",boundary];
        self.targetPath = filePath;
//        }else{
//            callback(@{@"error":@{@"code":@1,@"msg":@"DOWNLOAD_INVALID_ARGUMENT"}},nil);
//            return;
//        }
//        self.targetPath = filePath;
    }else{
        [target stringByAppendingString:@"/"];
        self.targetPath = target;
        self.randomPath = [target stringByDeletingLastPathComponent];
        NSString *boundary = [self md5:[@"nattransferdownload" stringByAppendingFormat:@"%lf",[[NSDate date] timeIntervalSince1970]]];
        self.randomPath = [self.randomPath stringByAppendingString:boundary];
        targetURL = [NSURL URLWithString:target];
        
    }
     NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:url];
    for (NSString *header in headers) {
        NSString *value = [headers objectForKey:header];
        [req setValue:value forHTTPHeaderField:header];
    }
    NSLog(@"%@",req.allHTTPHeaderFields);
   NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:NO];
    if (self.queue == nil) {
        self.queue = [[NSOperationQueue alloc] init];
    }
    [connection setDelegateQueue:self.queue];
    dispatch_async(
                   dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, (unsigned long)NULL),
                   ^(void) { [connection start];}
    );

}


- (void)upload:(NSDictionary *)params :(NatCallback)callback{
    if (!params || ![params isKindOfClass:[NSDictionary class]] || !params[@"path"] || !params[@"url"]) {
        callback(@{@"error":@{@"code":@153050,@"msg":@"UPLOAD_INVALID_ARGUMENT"}},nil);
        return;
    }
    self.transferTYpe = Nat_TRANSFER_UPLOAD;
    self.uploadback = callback;
    self.responseData = [NSMutableData data];
    
    NSURL *fileUrl = [NSURL URLWithString:params[@"path"]];
    NSURL *serverurl = [NSURL URLWithString:params[@"url"]];
//    NSData *fileData;
    if ([fileUrl.absoluteString hasPrefix:@"nat://static/image"]) {
        
        if ([[UIDevice currentDevice].systemVersion floatValue] >= 8)
        {
            NSString *str = [fileUrl absoluteString];
            str = [str substringFromIndex:19];
            PHFetchResult *result = [PHAsset fetchAssetsWithLocalIdentifiers:@[str] options:nil];
            [[PHImageManager defaultManager] requestImageDataForAsset:result.firstObject options:nil resultHandler:^(NSData * _Nullable imageData, NSString * _Nullable dataUTI, UIImageOrientation orientation, NSDictionary * _Nullable info) {
                
               NSString *mimeType = [NatTransfer getMimeTypeFromPath:info[@"PHImageFileURLKey"]];
                
                NSURL *path = info[@"PHImageFileURLKey"];
                NSArray *arr = [path.absoluteString componentsSeparatedByString:@"/"];
                
                
                [self uploadWithData:imageData fileUrl:fileUrl params:params serverurl:serverurl filename:arr.lastObject mimeType:mimeType];
            }];
            
            
            
        }else{
            NSString *str = [fileUrl absoluteString];
            str = [str substringFromIndex:19];
            str = [@"assets-library://" stringByAppendingString:str];
            __block ALAssetsLibrary *lib = [[ALAssetsLibrary alloc] init];
            
            [lib assetForURL:[NSURL URLWithString:str] resultBlock:^(ALAsset *asset) {
                
                ALAssetRepresentation *rep = [asset defaultRepresentation];
                Byte *buffer = (Byte*)malloc((unsigned long)rep.size);
                NSUInteger buffered = [rep getBytes:buffer fromOffset:0.0 length:((unsigned long)rep.size) error:nil];
                NSData *data = [NSData dataWithBytesNoCopy:buffer length:buffered freeWhenDone:YES];
                // UI的更新记得放在主线程,要不然等子线程排队过来都不知道什么年代了,会很慢的
                NSString *mimeType = [NatTransfer getMimeTypeFromPath:[[rep url] absoluteString]];
                [self uploadWithData:data fileUrl:fileUrl params:params serverurl:serverurl filename:[rep filename] mimeType:mimeType];

            } failureBlock:^(NSError *error) {
                callback(@{@"error":@{@"code":@153050,@"msg":@"UPLOAD_INVALID_ARGUMENT"}},nil);
                return;
            }];
        }

    }else{
        NSData *data = [NSData dataWithContentsOfFile:params[@"path"]];
        NSString *mimeType = [NatTransfer getMimeTypeFromPath:params[@"path"]];
        [self uploadWithData:data fileUrl:fileUrl params:params serverurl:serverurl filename:[params[@"path"] lastPathComponent] mimeType:mimeType];
    }
    
    
    
}

- (void)uploadWithData:(NSData *)data fileUrl:(NSURL *)fileUrl params:(NSDictionary *)params serverurl:(NSURL *)serverurl filename:(NSString *)filename mimeType:(NSString *)mimeType{
    if (data ==nil) {
        self.uploadback(@{@"error":@{@"code":@153050,@"msg":@"UPLOAD_INVALID_ARGUMENT"}},nil);
        return;
    }
    self.dataLenth = [data length];
    NSData *fileData = data;
    NSString *method = params[@"method"];
    if (method ==nil) {
        method = @"POST";
    }
    //    NSString* fileKey = @"file";
    //    NSString* fileName = @"image.jpg";
    if (params[@"mimeType"] && [params[@"mimeType"] isKindOfClass:[NSString class]] && ![params[@"mimeType"] isEqual:@""]) {
        mimeType = params[@"mimeType"];
    }
    NSString *boundary = [self md5:[@"nat" stringByAppendingFormat:@"%lf",[[NSDate date] timeIntervalSince1970]]];
    //cookie
    //    NSDictionary* options = nil;
    //    BOOL trustAllHosts = [[command argumentAtIndex:6 withDefault:[NSNumber numberWithBool:YES]] boolValue]; // allow self-signed certs
    NSDictionary* headers = params[@"header"];
    NSDictionary *formData = params[@"formData"];
    formData = @{@"name":@"huang",@"gender":@"man",@"platform":@"iOS"};
    if (params[@"filename"]) {
        filename = params[@"filename"];
    }
    // Allow alternative http method, default to POST. JS side checks
    // for allowed methods, currently PUT or POST (forces POST for
    // unrecognised values)
    //    NSString* httpMethod = @"POST";
    
    // NSURL does not accepts URLs with spaces in the path. We escape the path in order
    // to be more lenient.
    NSURL* url = [NSURL URLWithString:params[@"path"]];
    
    if (!url) {
        NSLog(@"File Transfer Error: Invalid server URL %@", serverurl);
    } else if (!fileData) {
        
    }
    
    
    NSMutableURLRequest* req = [NSMutableURLRequest requestWithURL:serverurl];
    
    [req setHTTPMethod:method];
    
    for (NSString *header in headers) {
        NSString *value = [headers objectForKey:header];
        [req setValue:value forHTTPHeaderField:header];
    }
    
    
    BOOL multipartFormUpload = [headers objectForKey:@"Content-Type"] == nil;
    if (multipartFormUpload) {
        NSString* contentType = [NSString stringWithFormat:@"multipart/form-data; boundary=%@",boundary];
        [req setValue:contentType forHTTPHeaderField:@"Content-Type"];
    }
    //    [self applyRequestHeaders:headers toRequest:req];
    
    NSData* formBoundaryData = [[NSString stringWithFormat:@"--%@\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];
    NSMutableData* postBodyBeforeFile = [NSMutableData data];
    NSArray *keys= [formData allKeys];
    //遍历keys
    for(int i=0;i<[keys count];i++)
    {
         NSString *key=[keys objectAtIndex:i];
        id val = [formData objectForKey:key];
        if (!val || (val == [NSNull null])) {
            continue;
        }
        // if it responds to stringValue selector (eg NSNumber) get the NSString
        if ([val respondsToSelector:@selector(stringValue)]) {
            val = [val stringValue];
        }
        // finally, check whether it is a NSString (for dataUsingEncoding selector below)
        if (![val isKindOfClass:[NSString class]]) {
            continue;
        }
        
        [postBodyBeforeFile appendData:formBoundaryData];
        [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"%@\"\r\n\r\n", key] dataUsingEncoding:NSUTF8StringEncoding]];
        [postBodyBeforeFile appendData:[val dataUsingEncoding:NSUTF8StringEncoding]];
            [postBodyBeforeFile appendData:[@"\r\n" dataUsingEncoding : NSUTF8StringEncoding]];

    }

    [postBodyBeforeFile appendData:formBoundaryData];
    
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Disposition: form-data; name=\"file\"; filename=\"%@\"\r\n", filename] dataUsingEncoding:NSUTF8StringEncoding]];
    NSString *str = [[NSString alloc] initWithData:postBodyBeforeFile encoding:NSUTF8StringEncoding];
    NSLog(@"%@",str);
    if (mimeType != nil){
        [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Type: %@\r\n", mimeType] dataUsingEncoding:NSUTF8StringEncoding]];
    }
    [postBodyBeforeFile appendData:[[NSString stringWithFormat:@"Content-Length: %ld\r\n\r\n", (long)[fileData length]] dataUsingEncoding:NSUTF8StringEncoding]];
    
    NSLog(@"fileData length: %ld", [fileData length]);
    NSData* postBodyAfterFile = [[NSString stringWithFormat:@"\r\n--%@--\r\n", boundary] dataUsingEncoding:NSUTF8StringEncoding];
    
    long long totalPayloadLength = [fileData length];
    if (multipartFormUpload) {
        totalPayloadLength += [postBodyBeforeFile length] + [postBodyAfterFile length];
    }
    
    [req setValue:[[NSNumber numberWithLongLong:totalPayloadLength] stringValue] forHTTPHeaderField:@"Content-Length"];
    
    //    if (chunkedMode) {
    //        CFReadStreamRef readStream = NULL;
    //        CFWriteStreamRef writeStream = NULL;
    //        CFStreamCreateBoundPair(NULL, &readStream, &writeStream, kStreamBufferSize);
    //        [req setHTTPBodyStream:CFBridgingRelease(readStream)];
    //
    //        [self.commandDelegate runInBackground:^{
    //            if (CFWriteStreamOpen(writeStream)) {
    //                if (multipartFormUpload) {
    //                    NSData* chunks[] = { postBodyBeforeFile, fileData, postBodyAfterFile };
    //                    int numChunks = sizeof(chunks) / sizeof(chunks[0]);
    //
    //                    for (int i = 0; i < numChunks; ++i) {
    //                        // Allow uploading of an empty file
    //                        if (chunks[i].length == 0) {
    //                            continue;
    //                        }
    //
    //                        CFIndex result = WriteDataToStream(chunks[i], writeStream);
    //                        if (result <= 0) {
    //                            break;
    //                        }
    //                    }
    //                } else {
    //                    if (totalPayloadLength > 0) {
    //                        WriteDataToStream(fileData, writeStream);
    //                    } else {
    //                        NSLog(@"Uploading of an empty file is not supported for chunkedMode=true and multipart=false");
    //                    }
    //                }
    //            } else {
    //                NSLog(@"FileTransfer: Failed to open writeStream");
    //            }
    //            CFWriteStreamClose(writeStream);
    //            CFRelease(writeStream);
    //        }];
    //    } else {
    if (multipartFormUpload) {
        [postBodyBeforeFile appendData:fileData];

        [postBodyBeforeFile appendData:postBodyAfterFile];
        [req setHTTPBody:postBodyBeforeFile];
    } else {
        [req setHTTPBody:fileData];
    }
    //    }
    //    return req;
    
    NSURLConnection *connection = [[NSURLConnection alloc] initWithRequest:req delegate:self startImmediately:NO];
    if (self.queue == nil) {
        self.queue = [[NSOperationQueue alloc] init];
    }
    [connection setDelegateQueue:self.queue];
    
    [connection start];

}


//判断文件是否存在
- (BOOL)ishasFile:(NSString *)path{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    
//    BOOL isDir = FALSE;
    
    BOOL isDirExist = [fileManager fileExistsAtPath:path];
    
    
    
        return isDirExist;
}
- (void)connection:(NSURLConnection*)connection didReceiveData:(NSData*)data
{
    self.bytesTransfered += data.length;
    
    if (self.targetFileHandle) {
        [self.targetFileHandle writeData:data];
    } else {
        [self.responseData appendData:data];
    }
    [self updateProgress];
    
}

- (void)updateProgress{
    if (self.transferTYpe == Nat_TRANSFER_DOWNLOAD) {
        BOOL lengthComputable = (self.bytesExpected != NSURLResponseUnknownLength);
        // If the response is GZipped, and we have an outstanding HEAD request to get
        // the length, then hold off on sending progress events.
        if (!lengthComputable) {
            return;
        }
        
        float alllength = [self.responseHeaders[@"Content-Length"] longLongValue] + 0.0;
        float loaded = self.bytesTransfered / alllength;
        if (loaded>=1.0) {
            loaded = 1;
        }
        NSMutableDictionary* downloadProgress = [NSMutableDictionary dictionaryWithCapacity:3];
        
//        [downloadProgress setObject:[NSNumber numberWithBool:lengthComputable] forKey:@"lengthComputable"];
        [downloadProgress setObject:[NSNumber numberWithFloat:loaded] forKey:@"progress"];
//        [downloadProgress setObject:[NSNumber numberWithLongLong:self.bytesExpected] forKey:@"total"];
        self.downloadback(nil,downloadProgress);
    }
}

- (void)connection:(NSURLConnection*)connection didReceiveResponse:(NSURLResponse*)response
{
    NSError* __autoreleasing error = nil;
    
//    self.mimeType = [response MIMEType];
    self.targetFileHandle = nil;
    // required for iOS 4.3, for some reason; response is
    // a plain NSURLResponse, not the HTTP subclass
    self.responseCode = (int)[(NSHTTPURLResponse*)response statusCode];
    self.bytesExpected = [response expectedContentLength];

    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
        NSHTTPURLResponse* httpResponse = (NSHTTPURLResponse*)response;
        NSLog(@"%@",httpResponse);
        self.responseHeaders = [httpResponse allHeaderFields];
        if ((self.transferTYpe == Nat_TRANSFER_DOWNLOAD) && (self.responseCode == 200) && (self.bytesExpected == NSURLResponseUnknownLength)) {
            // Kick off HEAD request to server to get real length
            // bytesExpected will be updated when that response is returned
            NSMutableURLRequest* req = [connection.currentRequest mutableCopy];
            [req setHTTPMethod:@"HEAD"];
            [req setValue:@"identity" forHTTPHeaderField:@"Accept-Encoding"];
           NSURLConnection *connection = [NSURLConnection connectionWithRequest:req delegate:self];
        }
    } else if ([response.URL isFileURL]) {
        NSDictionary* attr = [[NSFileManager defaultManager] attributesOfItemAtPath:[response.URL path] error:nil];
        self.responseCode = 200;
        self.bytesExpected = [attr[NSFileSize] longLongValue];
    } else {
        self.responseCode = 200;
        self.bytesExpected = NSURLResponseUnknownLength;
    }
    if ((self.transferTYpe == Nat_TRANSFER_DOWNLOAD) && (self.responseCode >= 200) && (self.responseCode < 300)) {
        // Download response is okay; begin streaming output to file
        NSString *filePath;
//        NSString *filename;
        if (self.downfilename) {
            filePath = [self.targetPath stringByAppendingFormat:@"/%@",self.downfilename];
        }else if (self.responseHeaders[@"Content-Disposition"]) {
           self.downfilename = [[[self.responseHeaders[@"Content-Disposition"] componentsSeparatedByString:@"="] lastObject] stringByReplacingOccurrencesOfString:@"\"" withString:@""];
            
            filePath = [self.targetPath stringByAppendingFormat:@"/%@",self.downfilename];
            
            
        }else{
            NSArray *arr = [response.URL.absoluteString componentsSeparatedByString:@"/"];
            
            filePath = [self.targetPath stringByAppendingFormat:@"/%@",arr.lastObject];
            self.downfilename = arr.lastObject;
        }
        self.targetPath = filePath;
        
        if (filePath == nil) {

            [self cancelTransfer:connection];
            return;
        }

        NSString* parentPath = [self.randomPath stringByDeletingLastPathComponent];
        

        if ([[NSFileManager defaultManager] createDirectoryAtPath:parentPath withIntermediateDirectories:YES attributes:nil error:&error] == NO) {
            if (error) {
                [self cancelTransfer:connection];
            } else {
                [self cancelTransfer:connection];
            }
            return;
        }
        // create target file
        if ([[NSFileManager defaultManager] createFileAtPath:self.randomPath contents:nil attributes:nil] == NO) {
            [self cancelTransfer:connection];
            return;
        }
        // open target file for writing
        self.targetFileHandle = [NSFileHandle fileHandleForWritingAtPath:self.randomPath];
        if (self.targetFileHandle == nil) {
            [self cancelTransfer:connection];
        }
    }
}


- (void)connection:(NSURLConnection*)connection didFailWithError:(NSError*)error
{
    [self cancelTransfer:connection];
    
}

- (void)connection:(NSURLConnection*)connection didSendBodyData:(NSInteger)bytesWritten totalBytesWritten:(NSInteger)totalBytesWritten totalBytesExpectedToWrite:(NSInteger)totalBytesExpectedToWrite{
    if (self.transferTYpe == Nat_TRANSFER_UPLOAD) {
        NSMutableDictionary* uploadProgress = [NSMutableDictionary dictionaryWithCapacity:3];
        float allData = self.dataLenth + 0.0;
        float loaded = totalBytesWritten / allData;
//        float total = totalBytesExpectedToWrite / self.dataLenth;
//        [uploadProgress setObject:[NSNumber numberWithBool:true] forKey:@"lengthComputable"];
        if (loaded>=1.0) {
            loaded = 1;
        }
        [uploadProgress setObject:[NSNumber numberWithFloat:loaded] forKey:@"progress"];
//        [uploadProgress setObject:[NSNumber numberWithLongLong:total] forKey:@"total"];
        self.uploadback(nil,uploadProgress);
    }
    self.bytesTransfered = totalBytesWritten;
}

- (void)connection:(NSURLConnection*)connection willSendRequestForAuthenticationChallenge:(NSURLAuthenticationChallenge*)challenge
{
    if ([challenge.protectionSpace.authenticationMethod isEqualToString:NSURLAuthenticationMethodServerTrust]) {
            NSURLCredential* credential = [NSURLCredential credentialForTrust:challenge.protectionSpace.serverTrust];
            [challenge.sender useCredential:credential forAuthenticationChallenge:challenge];
        [challenge.sender continueWithoutCredentialForAuthenticationChallenge:challenge];
    } else {
        [challenge.sender performDefaultHandlingForAuthenticationChallenge:challenge];
    }
}

- (void)connectionDidFinishLoading:(NSURLConnection*)connection
{
    NSString* uploadResponse = nil;
    NSString* downloadResponse = nil;
//    NSMutableDictionary* uploadResult;
    if (self.transferTYpe == Nat_TRANSFER_UPLOAD) {
        uploadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
        if ((self.responseCode >= 200) && (self.responseCode < 300)) {
            self.uploadback(nil,@{@"progress":@1});
            NSMutableDictionary *resultDic = @{@"status":@200,@"ok":@1,@"statusText":@"OK"}.mutableCopy;
            if (self.responseHeaders) {
                [resultDic setObject:self.responseHeaders forKey:@"headers"];
            }
            if (self.responseData) {
                 NSString *responseData = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
                [resultDic setObject:responseData forKey:@"data"];
            }
            
            self.uploadback(nil,resultDic);
        } else {
            self.uploadback(@{@"error":@{@"code":@153000,@"msg":@"UPLOAD_INTERNAL_ERROR"}},nil);
        }
    }else{
        if (self.targetFileHandle) {
            self.downloadback(nil,@{@"progress":@1});
            [self.targetFileHandle closeFile];
            if ([self ishasFile:self.targetPath]) {
                //文件已存在
//                NSString *string = [[self.targetPath componentsSeparatedByString:@"/"] lastObject];
                
            
                
                NSArray *fileArr = [NatTransfer filenameandtypeWithString:self.downfilename];
                
                
                NSString *file = [fileArr firstObject];
                NSString *type = [fileArr lastObject];
                
                NSInteger i = 1;
//                NSString *filename = [file stringByAppendingFormat:@"(i).%@",type];
                while ([self ishasFile:[[self.randomPath stringByDeletingLastPathComponent] stringByAppendingFormat:@"/%@(%ld)%@",file,i,type]]) {
                    i++;
                }
                NSError *error;
                [[NSFileManager defaultManager] moveItemAtPath:self.randomPath toPath:[[self.randomPath stringByDeletingLastPathComponent] stringByAppendingFormat:@"/%@(%ld)%@",file,i,type] error:&error];
                if (error) {
                     [[NSFileManager defaultManager] removeItemAtPath:self.randomPath error:nil];
                    self.downloadback(@{@"error":@{@"code":@152000,@"msg":@"DOWNLOAD_INTERNAL_ERROR",@"details":error.localizedDescription}},nil);
                    return;
                }
                
            }else{
                NSError *error;
                NSFileManager *fileManager = [NSFileManager defaultManager];
                [fileManager moveItemAtPath:self.randomPath toPath:self.targetPath error:&error];
                if (error) {
                    [fileManager removeItemAtPath:self.randomPath error:nil];
                    self.downloadback(@{@"error":@{@"code":@152000,@"msg":@"DOWNLOAD_INTERNAL_ERROR",@"details":error.localizedDescription}},nil);
                    return;
                }
            }
            
            self.targetFileHandle = nil;
            NSMutableDictionary *resultDic = @{@"status":@200,@"ok":@1,@"statusText":@"OK"}.mutableCopy;
            if (self.responseHeaders) {
                [resultDic setObject:self.responseHeaders forKey:@"headers"];
            }
            NSLog(@"%@",resultDic);
            self.downloadback(nil,resultDic);
        } else {
            downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSUTF8StringEncoding];
            if (downloadResponse == nil) {
                downloadResponse = [[NSString alloc] initWithData:self.responseData encoding:NSISOLatin1StringEncoding];
            }
            self.downloadback(@{@"error":@{@"code":@152000,@"msg":@"DOWNLOAD_INTERNAL_ERROR"}},nil);
        }
    }
    
    
    // remove connection for activeTransfers

}

- (void)removeTargetFile
{
    NSFileManager* fileMgr = [NSFileManager defaultManager];
    
    NSString *targetPath = self.randomPath;
    if ([fileMgr fileExistsAtPath:targetPath])
    {
        [fileMgr removeItemAtPath:targetPath error:nil];
    }
}

- (void)cancelTransfer:(NSURLConnection*)connection{
    [connection cancel];
    if (self.transferTYpe == Nat_TRANSFER_DOWNLOAD) {
        [self removeTargetFile];
        self.downloadback(@{@"error":@{@"code":@152060,@"msg":@"DOWNLOAD_NETWORK_ERROR"}},nil);
    }else{
        self.uploadback(@{@"error":@{@"code":@153060,@"msg":@"UPLOAD_NETWORK_ERROR"}},nil);
    }

}


+ (NSString *)stringWithDictionary:(NSDictionary *)dictionary
{
    if([NSJSONSerialization isValidJSONObject:dictionary])
    {
        NSError *error = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:dictionary options:0 error:&error];
        if(!error)
        {
            return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        }
    }
    return nil;
}

- (NSString *)md5:(NSString *)string
{
    const char *original_str = [string UTF8String];
    unsigned char result[CC_MD5_DIGEST_LENGTH];
    CC_MD5(original_str, (CC_LONG)strlen(original_str), result);
    NSMutableString *hash = [NSMutableString string];
    for (int i = 0; i < 16; i++)
        [hash appendFormat:@"%02X", result[i]];
    return [hash lowercaseString];
}
+ (NSString*)getMimeTypeFromPath:(NSString*)fullPath
{
    NSString* mimeType = nil;
    
    if (fullPath) {
        CFStringRef typeId = UTTypeCreatePreferredIdentifierForTag(kUTTagClassFilenameExtension, (__bridge CFStringRef)[fullPath pathExtension], NULL);
        if (typeId) {
            mimeType = (__bridge_transfer NSString*)UTTypeCopyPreferredTagWithClass(typeId, kUTTagClassMIMEType);
            if (!mimeType) {
                // special case for m4a
                if ([(__bridge NSString*)typeId rangeOfString : @"m4a-audio"].location != NSNotFound) {
                    mimeType = @"audio/mp4";
                } else if ([[fullPath pathExtension] rangeOfString:@"wav"].location != NSNotFound) {
                    mimeType = @"audio/wav";
                } else if ([[fullPath pathExtension] rangeOfString:@"css"].location != NSNotFound) {
                    mimeType = @"text/css";
                }
            }
            CFRelease(typeId);
        }
    }
    return mimeType;
}
+ (NSArray *)filenameandtypeWithString:(NSString *)str
{
    if (!str.length )
    {
        return nil;
    }
    NSMutableArray *resultArr= [NSMutableArray arrayWithCapacity:0];
    NSString *pattern = @"(.*)(\\.\\w+)$";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSArray *matches = [regex matchesInString:str options:0 range:NSMakeRange(0, str.length)];
    
    if (matches) {
        NSTextCheckingResult* match = matches.firstObject;
        NSString *start = [str substringWithRange:[match rangeAtIndex:1]];
        NSString *end = [str substringWithRange:[match rangeAtIndex:2]];
        [resultArr addObject:start];
        [resultArr addObject:end];
    }else{
        [resultArr addObject:str];
        [resultArr addObject:@""];
    }
    return resultArr;
}

@end
