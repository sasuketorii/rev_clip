#import "RCSVGPreview.h"
#import <math.h>

static const NSUInteger RCInputLimit = 128 * 1024;
static BOOL RCMatch(NSString *s, NSString *pattern) {
    // Two fixed grammar patterns; compile once per pattern instead of once per path number.
    static NSMutableDictionary<NSString *, NSRegularExpression *> *patterns;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ patterns = [NSMutableDictionary dictionary]; });
    NSRegularExpression *regex;
    @synchronized (patterns) {
        regex = patterns[pattern];
        if (!regex) {
            regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:NULL];
            if (regex) patterns[pattern] = regex;
        }
    }
    return [regex firstMatchInString:s options:0 range:NSMakeRange(0,s.length)] != nil;
}
static NSString *RCTrim(NSString *s) {
    return [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}
static BOOL RCNumber(NSString *s, double *out) {
    if (!RCMatch(s, @"\\A[+-]?(?:[0-9]+(?:\\.[0-9]*)?|\\.[0-9]+)(?:[eE][+-]?[0-9]+)?\\z")) return NO;
    double n = s.doubleValue;
    if (!isfinite(n) || fabs(n) > 16384) return NO;
    if (out) *out = n;
    return YES;
}
// Bounded numeric lists. Reject stray/trailing commas and non-SVG numeric syntax.
static NSArray<NSNumber *> *RCParsedNumbers(NSString *s, BOOL arc) {
    NSScanner *scanner = [NSScanner scannerWithString:s];
    scanner.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    scanner.charactersToBeSkipped = nil;
    NSMutableArray *numbers = [NSMutableArray array];
    NSCharacterSet *ws = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n"];
    [scanner scanCharactersFromSet:ws intoString:NULL];
    while (!scanner.isAtEnd) {
        // scanDouble handles adjacent signed numbers; validate each consumed token separately.
        NSUInteger start = scanner.scanLocation;
        double value;
        BOOL flag = arc && (numbers.count % 7 == 3 || numbers.count % 7 == 4);
        if (flag) {
            unichar c = [s characterAtIndex:start];
            if (c != '0' && c != '1') return nil;
            value = c - '0'; scanner.scanLocation = start + 1;
        } else if (![scanner scanDouble:&value] || scanner.scanLocation == start) return nil;
        NSString *token = [s substringWithRange:NSMakeRange(start, scanner.scanLocation-start)];
        if (!RCNumber(token, &value) || numbers.count >= 8192) return nil;
        [numbers addObject:@(value)];
        BOOL spaced = [scanner scanCharactersFromSet:ws intoString:NULL];
        if ([scanner scanString:@"," intoString:NULL]) {
            [scanner scanCharactersFromSet:ws intoString:NULL];
            if (scanner.isAtEnd || [s characterAtIndex:scanner.scanLocation] == ',') return nil;
        } else if (!scanner.isAtEnd && !spaced) {
            unichar c = [s characterAtIndex:scanner.scanLocation];
            // SVG permits adjacent decimals (e.g. .273.049) and single-digit arc flags.
            if (c != '+' && c != '-' && c != '.' && !(flag && c >= '0' && c <= '9')) return nil;
        }
    }
    return numbers;
}
static NSArray<NSNumber *> *RCNumbers(NSString *s) { return RCParsedNumbers(s, NO); }
static BOOL RCPath(NSString *s) {
    if (!s.length || s.length > 65536) return NO;
    NSCharacterSet *commands = [NSCharacterSet characterSetWithCharactersInString:@"MmLlHhVvCcSsQqTtAaZz"];
    NSUInteger i = 0, segments = 0;
    BOOL first = YES;
    while (i < s.length) {
        while (i < s.length && [[NSCharacterSet whitespaceAndNewlineCharacterSet] characterIsMember:[s characterAtIndex:i]]) i++;
        if (i == s.length) break;
        unichar c = [s characterAtIndex:i++];
        if (![commands characterIsMember:c] || (first && c != 'M' && c != 'm')) return NO;
        first = NO;
        NSUInteger start = i;
        while (i < s.length && ![commands characterIsMember:[s characterAtIndex:i]]) i++;
        unichar upper = (c >= 'a' && c <= 'z') ? c - 32 : c;
        NSArray<NSNumber *> *n = RCParsedNumbers([s substringWithRange:NSMakeRange(start, i-start)], upper == 'A');
        if (!n) return NO;
        NSUInteger arity = upper == 'Z' ? 0 : (upper == 'H' || upper == 'V') ? 1 : upper == 'C' ? 6 : (upper == 'S' || upper == 'Q') ? 4 : upper == 'A' ? 7 : 2;
        if (arity == 0) { if (n.count) return NO; }
        else {
            if (!n.count || n.count % arity) return NO;
            segments += n.count / arity;
            if (upper == 'A') for (NSUInteger j = 0; j < n.count; j += 7) {
                if (n[j].doubleValue < 0 || n[j+1].doubleValue < 0 ||
                    (n[j+3].doubleValue != 0 && n[j+3].doubleValue != 1) ||
                    (n[j+4].doubleValue != 0 && n[j+4].doubleValue != 1)) return NO;
            }
        }
        if (segments > 4096) return NO;
    }
    return !first;
}
static BOOL RCTransform(NSString *s, double *budget) {
    NSScanner *scan = [NSScanner scannerWithString:s];
    scan.charactersToBeSkipped = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    NSUInteger count = 0;
    while (!scan.isAtEnd) {
        NSString *name, *args;
        if (++count > 16 || ![scan scanCharactersFromSet:NSCharacterSet.letterCharacterSet intoString:&name] ||
            ![scan scanString:@"(" intoString:NULL]) return NO;
        if (![scan scanUpToString:@")" intoString:&args] || ![scan scanString:@")" intoString:NULL]) return NO;
        NSArray *n = RCNumbers(args);
        if (!n) return NO;
        BOOL valid = ([name isEqual:@"matrix"] && n.count == 6) ||
            (([name isEqual:@"translate"] || [name isEqual:@"scale"]) && (n.count == 1 || n.count == 2)) ||
            ([name isEqual:@"rotate"] && (n.count == 1 || n.count == 3));
        if (!valid) return NO;
        double factor = 1;
        for (NSNumber *v in n) {
            if (fabs(v.doubleValue) > 1024) return NO;
            factor += fabs(v.doubleValue);
        }
        // Rotation angle does not amplify coordinates; a center can add translation.
        if ([name isEqual:@"rotate"]) factor = n.count == 1 ? 2 : 2 + 4*(fabs([n[1] doubleValue])+fabs([n[2] doubleValue]));
        *budget *= factor;
        if (!isfinite(*budget) || *budget > 16384) return NO;
    }
    return count > 0;
}
static NSString *RCEscape(NSString *s) {
    s = [s stringByReplacingOccurrencesOfString:@"&" withString:@"&amp;"];
    s = [s stringByReplacingOccurrencesOfString:@"\"" withString:@"&quot;"];
    s = [s stringByReplacingOccurrencesOfString:@"<" withString:@"&lt;"];
    return s;
}
static NSString *RCTint(NSColor *color, double *alpha) {
    NSColor *rgb = [color colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
    if (!rgb || !isfinite(rgb.redComponent) || !isfinite(rgb.greenComponent) ||
        !isfinite(rgb.blueComponent) || !isfinite(rgb.alphaComponent)) return nil;
    *alpha = fmax(0, fmin(1, rgb.alphaComponent));
    return [NSString stringWithFormat:@"#%02X%02X%02X", (unsigned)lround(fmax(0,fmin(1,rgb.redComponent))*255),
        (unsigned)lround(fmax(0,fmin(1,rgb.greenComponent))*255), (unsigned)lround(fmax(0,fmin(1,rgb.blueComponent))*255)];
}

@interface RCSVGReader : NSObject <NSXMLParserDelegate>
@property NSMutableString *output;
@property NSMutableArray<NSString *> *stack;
@property NSMutableArray<NSNumber *> *transformBudgets;
@property NSString *tint;
@property double alpha;
@property NSUInteger nodes;
@property NSUInteger pathBytes;
@property BOOL failed;
@property BOOL rootSeen;
@end
@implementation RCSVGReader
- (void)reject:(NSXMLParser *)parser { self.failed = YES; [parser abortParsing]; }
- (void)parser:(NSXMLParser *)parser didStartElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified attributes:(NSDictionary<NSString *,NSString *> *)attrs {
    BOOL root = self.stack.count == 0;
    if (++self.nodes > 512 || self.stack.count >= 32 || attrs.count > 24 ||
        (root && (self.rootSeen || ![name isEqual:@"svg"])) ||
        (!root && ![@[@"g", @"path", @"rect", @"circle", @"ellipse", @"line", @"polyline", @"polygon"] containsObject:name]) ||
        (!root && ![@[@"svg", @"g"] containsObject:self.stack.lastObject])) { [self reject:parser]; return; }
    double transformBudget = self.transformBudgets.lastObject ? self.transformBudgets.lastObject.doubleValue : 1;
    NSMutableDictionary *safe = [NSMutableDictionary dictionary];
    static NSDictionary *geometry;
    static dispatch_once_t geometryOnce;
    dispatch_once(&geometryOnce, ^{ geometry = @{@"path": @[@"d"], @"rect": @[@"x",@"y",@"width",@"height",@"rx",@"ry"],
        @"circle": @[@"cx",@"cy",@"r"], @"ellipse": @[@"cx",@"cy",@"rx",@"ry"],
        @"line": @[@"x1",@"y1",@"x2",@"y2"], @"polyline": @[@"points"], @"polygon": @[@"points"]}; });
    for (NSString *key in attrs) {
        NSString *v = RCTrim(attrs[key]);
        BOOL valid = NO;
        if (root && [key isEqual:@"xmlns"]) valid = [v isEqual:@"http://www.w3.org/2000/svg"];
        else if (root && [key isEqual:@"viewBox"]) {
            NSArray<NSNumber *> *n = RCNumbers(v);
            valid = n.count == 4 && n[2].doubleValue >= 0.0001 && n[3].doubleValue >= 0.0001 && n[2].doubleValue*n[3].doubleValue <= 67108864 && n[2].doubleValue/n[3].doubleValue <= 1024 && n[3].doubleValue/n[2].doubleValue <= 1024;
        } else if ([key isEqual:@"fill"] || [key isEqual:@"stroke"]) {
            // Paint values are discarded, but only simple color syntax is admitted. No CSS functions/references.
            valid = [v isEqual:@"none"] || [v isEqual:@"currentColor"] ||
                RCMatch(v, @"\\A(?:#[0-9a-fA-F]{3}|#[0-9a-fA-F]{6})\\z") ||
                [@[@"black",@"silver",@"gray",@"white",@"maroon",@"red",@"purple",@"fuchsia",@"green",@"lime",@"olive",@"yellow",@"navy",@"blue",@"teal",@"aqua",@"orange",@"transparent"] containsObject:v.lowercaseString];
            if ([v.lowercaseString isEqual:@"transparent"]) v = @"none";
            if (valid && ![v isEqual:@"none"]) v = self.tint;
        } else if ([key isEqual:@"fill-rule"] || [key isEqual:@"clip-rule"]) valid = [@[@"evenodd",@"nonzero"] containsObject:v];
        else if ([key isEqual:@"stroke-linecap"]) valid = [@[@"butt",@"round",@"square"] containsObject:v];
        else if ([key isEqual:@"stroke-linejoin"]) valid = [@[@"miter",@"round",@"bevel"] containsObject:v];
        else if ([key isEqual:@"transform"] && !root) valid = RCTransform(v, &transformBudget);
        else if ([key isEqual:@"d"] && [name isEqual:@"path"]) {
            self.pathBytes += v.length;
            valid = self.pathBytes <= 65536 && RCPath(v);
        } else if ([key isEqual:@"points"] && [geometry[name] containsObject:key]) {
            NSArray *n = RCNumbers(v); valid = n.count >= 4 && n.count % 2 == 0;
        } else if ([key isEqual:@"opacity"] || [key isEqual:@"fill-opacity"] || [key isEqual:@"stroke-opacity"]) {
            double n; valid = RCNumber(v, &n) && n >= 0 && n <= 1;
        } else if ([key isEqual:@"stroke-width"] || [geometry[name] containsObject:key] ||
                   (root && ( [key isEqual:@"width"] || [key isEqual:@"height"]))) {
            double n; valid = RCNumber(v, &n);
            if ([@[@"width",@"height",@"r",@"rx",@"ry"] containsObject:key]) valid = valid && n > 0;
            if ([key isEqual:@"stroke-width"]) valid = valid && n >= 0 && n <= 1024;
        }
        if (!valid) { [self reject:parser]; return; }
        safe[key] = v;
    }
    if ([name isEqual:@"path"] && !safe[@"d"]) { [self reject:parser]; return; }
    if (root) {
        self.rootSeen = YES;
        NSArray<NSNumber *> *box = safe[@"viewBox"] ? RCNumbers(safe[@"viewBox"]) : nil;
        double w = safe[@"width"] ? [safe[@"width"] doubleValue] : (box ? box[2].doubleValue : 0);
        double h = safe[@"height"] ? [safe[@"height"] doubleValue] : (box ? box[3].doubleValue : 0);
        if (w < 0.0001 || h < 0.0001 || w*h > 67108864 || w/h > 1024 || h/w > 1024) { [self reject:parser]; return; }
        if (!box) safe[@"viewBox"] = [NSString stringWithFormat:@"0 0 %.9g %.9g",w,h];
        double factor = fmin(1, 720/fmax(w,h));
        safe[@"width"] = [NSString stringWithFormat:@"%.9g",w*factor];
        safe[@"height"] = [NSString stringWithFormat:@"%.9g",h*factor];
        safe[@"xmlns"] = @"http://www.w3.org/2000/svg";
        if (!safe[@"fill"]) safe[@"fill"] = self.tint;
    }
    [self.output appendFormat:@"<%@",name];
    for (NSString *key in [[safe allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [self.output appendFormat:@" %@=\"%@\"",key,RCEscape(safe[key])];
    [self.output appendString:@">"];
    if (root) [self.output appendFormat:@"<g opacity=\"%.9g\">",self.alpha];
    [self.stack addObject:name];
    [self.transformBudgets addObject:@(transformBudget)];
    if (self.output.length > 256*1024) [self reject:parser];
}
- (void)parser:(NSXMLParser *)parser didEndElement:(NSString *)name namespaceURI:(NSString *)uri qualifiedName:(NSString *)qualified {
    if (![self.stack.lastObject isEqual:name]) { [self reject:parser]; return; }
    if (self.stack.count == 1) [self.output appendString:@"</g>"];
    [self.output appendFormat:@"</%@>", name]; [self.stack removeLastObject]; [self.transformBudgets removeLastObject];
}
- (void)parser:(NSXMLParser *)parser foundCharacters:(NSString *)string { if (RCTrim(string).length) [self reject:parser]; }
- (void)parser:(NSXMLParser *)parser foundCDATA:(NSData *)data { [self reject:parser]; }
- (void)parser:(NSXMLParser *)parser foundProcessingInstructionWithTarget:(NSString *)target data:(NSString *)data { [self reject:parser]; }
- (NSData *)parser:(NSXMLParser *)parser resolveExternalEntityName:(NSString *)name systemID:(NSString *)systemID { [self reject:parser]; return nil; }
@end

@implementation RCSVGPreview
+ (BOOL)isCandidateString:(NSString *)text {
    if (!text.length || text.length > RCInputLimit) return NO;
    NSString *s = RCTrim(text);
    // Deliberately excludes XML declarations, markdown fences and surrounding prose.
    if (![s hasPrefix:@"<svg"] || s.length < 6) return NO;
    unichar c = [s characterAtIndex:4];
    return c == '>' || c == '/' || c == ' ' || c == '\n' || c == '\r' || c == '\t';
}
+ (NSData *)validatedSVGDataForString:(NSString *)text color:(NSColor *)color {
    if (![self isCandidateString:text]) return nil;
    NSData *input = [text dataUsingEncoding:NSUTF8StringEncoding allowLossyConversion:NO];
    if (!input || input.length > RCInputLimit || [text rangeOfString:@"<!"].location != NSNotFound) return nil;
    double alpha;
    NSString *tint = RCTint(color, &alpha);
    if (!tint) return nil;
    RCSVGReader *reader = [RCSVGReader new];
    reader.output = [NSMutableString string]; reader.stack = [NSMutableArray array]; reader.transformBudgets = [NSMutableArray array]; reader.tint = tint; reader.alpha = alpha;
    NSXMLParser *parser = [[NSXMLParser alloc] initWithData:input];
    parser.shouldResolveExternalEntities = NO;
    parser.externalEntityResolvingPolicy = NSXMLParserResolveExternalEntitiesNever;
    parser.delegate = reader;
    if (![parser parse] || reader.failed || !reader.rootSeen || reader.stack.count) return nil;
    NSData *result = [reader.output dataUsingEncoding:NSUTF8StringEncoding];
    return result.length <= 256*1024 ? result : nil;
}
+ (NSImage *)imageForString:(NSString *)text color:(NSColor *)color size:(CGFloat)size {
    if (![self isCandidateString:text] || !isfinite(size) || size <= 0) return nil;
    double alpha; NSString *tint = RCTint(color, &alpha);
    if (!tint) return nil;
    NSUInteger edge = (NSUInteger)ceil(fmin(720, size));
    NSArray *key = @[[text copy], tint, @(alpha), @(edge)];
    static NSMutableDictionary<NSArray *, NSImage *> *cache;
    static NSMutableArray<NSArray *> *order;
    static NSUInteger cost;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary dictionary]; order = [NSMutableArray array]; });
    // Serialize misses too: avoids duplicate native decodes and unbounded concurrent bitmap allocation.
    @synchronized (cache) {
        NSImage *hit = cache[key];
        if (hit) { [order removeObject:key]; [order addObject:key]; return [hit copy]; }
        @autoreleasepool {
            NSData *data = [self validatedSVGDataForString:text color:color];
            if (!data) return nil;
            NSImage *source = [[NSImage alloc] initWithData:data];
            NSSize natural = source.size;
            if (!source || !isfinite(natural.width) || !isfinite(natural.height) || natural.width <= 0 || natural.height <= 0) return nil;
            double scale = edge / fmax(natural.width,natural.height);
            NSInteger w = MAX(1, (NSInteger)ceil(natural.width*scale)), h = MAX(1, (NSInteger)ceil(natural.height*scale));
            w = MIN(720,w); h = MIN(720,h);
            NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:w*4 bitsPerPixel:32];
            if (!bitmap) return nil;
            memset(bitmap.bitmapData, 0, bitmap.bytesPerRow*h);
            NSGraphicsContext *context = [NSGraphicsContext graphicsContextWithBitmapImageRep:bitmap];
            if (!context) return nil;
            [NSGraphicsContext saveGraphicsState];
            @try {
                NSGraphicsContext.currentContext = context;
                [source drawInRect:NSMakeRect(0,0,w,h) fromRect:NSZeroRect operation:NSCompositingOperationCopy fraction:1 respectFlipped:NO hints:nil];
            } @catch (NSException *exception) {
                return nil;
            } @finally { [NSGraphicsContext restoreGraphicsState]; }
            NSImage *result = [[NSImage alloc] initWithSize:NSMakeSize(w,h)]; [result addRepresentation:bitmap];
            // Includes conservative UTF-16 key storage as well as the raster bytes.
            NSUInteger entryCost = w*h*4 + text.length*2 + 1024;
            while (order.count && (order.count >= 8 || cost + entryCost > 16*1024*1024)) {
                NSArray *old = order.firstObject; NSImage *oldImage = cache[old];
                cost -= (NSUInteger)oldImage.size.width*(NSUInteger)oldImage.size.height*4 + [old[0] length]*2 + 1024;
                [cache removeObjectForKey:old]; [order removeObjectAtIndex:0];
            }
            cache[key] = result; [order addObject:key]; cost += entryCost;
            return [result copy];
        }
    }
}
@end
