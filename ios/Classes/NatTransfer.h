//
//  NatTransfer.h
//
//  Created by huangyake on 17/1/7.
//  Copyright © 2017 Instapp. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface NatTransfer : NSObject

typedef void (^NatCallback)(id error, id result);
- (void)download:(NSDictionary *)params :(NatCallback)callback;
- (void)upload:(NSDictionary *)params :(NatCallback)callback;

@end
