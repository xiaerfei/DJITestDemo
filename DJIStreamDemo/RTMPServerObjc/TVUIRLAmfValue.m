//
//  TVUIRLAmfValue.m
//  DJIStreamDemo
//

#import "TVUIRLAmfValue.h"

@interface TVUIRLAmfValue ()
@property (nonatomic, assign) TVUIRLAmfValueType type;
@property (nonatomic, assign) double doubleStorage;
@property (nonatomic, assign) BOOL boolStorage;
@property (nonatomic, copy, nullable) NSString *stringStorage;
@property (nonatomic, copy, nullable) NSDictionary<NSString *, TVUIRLAmfValue *> *objectStorage;
@property (nonatomic, copy, nullable) NSArray<TVUIRLAmfValue *> *arrayStorage;
@property (nonatomic, copy, nullable) NSDate *dateStorage;
@property (nonatomic, copy, nullable) NSString *typedObjectName;
@end

@implementation TVUIRLAmfValue

+ (instancetype)valueWithType:(TVUIRLAmfValueType)type {
    TVUIRLAmfValue *v = [[TVUIRLAmfValue alloc] init];
    v.type = type;
    return v;
}

+ (instancetype)numberValue:(double)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeNumber];
    v.doubleStorage = value;
    return v;
}

+ (instancetype)boolValue:(BOOL)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeBoolean];
    v.boolStorage = value;
    return v;
}

+ (instancetype)stringValue:(NSString *)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeString];
    v.stringStorage = [value copy];
    return v;
}

+ (instancetype)objectValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeObject];
    v.objectStorage = [value copy];
    return v;
}

+ (instancetype)nullValue { return [self valueWithType:TVUIRLAmfValueTypeNull]; }
+ (instancetype)undefinedValue { return [self valueWithType:TVUIRLAmfValueTypeUndefined]; }
+ (instancetype)referenceValue { return [self valueWithType:TVUIRLAmfValueTypeReference]; }
+ (instancetype)unsupportedValue { return [self valueWithType:TVUIRLAmfValueTypeUnsupported]; }
+ (instancetype)avmplushValue { return [self valueWithType:TVUIRLAmfValueTypeAvmplush]; }

+ (instancetype)ecmaArrayValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeEcmaArray];
    v.objectStorage = [value copy];
    return v;
}

+ (instancetype)strictArrayValue:(NSArray<TVUIRLAmfValue *> *)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeStrictArray];
    v.arrayStorage = [value copy];
    return v;
}

+ (instancetype)dateValue:(NSDate *)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeDate];
    v.dateStorage = [value copy];
    return v;
}

+ (instancetype)xmlDocumentValue:(NSString *)value {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeXmlDocument];
    v.stringStorage = [value copy];
    return v;
}

+ (instancetype)typedObjectValue:(NSDictionary<NSString *, TVUIRLAmfValue *> *)value type:(NSString *)typeName {
    TVUIRLAmfValue *v = [self valueWithType:TVUIRLAmfValueTypeTypedObject];
    v.objectStorage = [value copy];
    v.typedObjectName = [typeName copy];
    return v;
}

- (double)doubleValue { return self.doubleStorage; }
- (BOOL)boolValue { return self.boolStorage; }
- (NSString *)stringValue { return self.stringStorage; }
- (NSDictionary<NSString *, TVUIRLAmfValue *> *)objectValue { return self.objectStorage; }
- (NSArray<TVUIRLAmfValue *> *)strictArrayValue { return self.arrayStorage; }
- (NSDate *)dateValue { return self.dateStorage; }
- (NSString *)xmlDocumentString { return self.stringStorage; }

@end
