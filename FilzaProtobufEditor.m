#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sys/stat.h>
#import "FilzaProtobufCodec.h"
#import "FilzaDiagnostics.h"

// A separate text surface for reversible Protobuf normalization, integrated
// at the existing Filza browser's file-open action. Unknown file types continue
// through the original Filza selection handler without modification.
@interface FPBTextEditorController : UIViewController <UITextViewDelegate>
@property(nonatomic, copy) NSString *filePath;
@property(nonatomic, strong) NSData *originalBytes;
@property(nonatomic, copy) NSString *initialJSON;
@property(nonatomic, strong) UITextView *textView;
@end

@implementation FPBTextEditorController

- (instancetype)initWithPath:(NSString *)path
                        bytes:(NSData *)data
                     document:(NSDictionary *)document {
    self = [super initWithNibName:nil bundle:nil];
    if (self) {
        _filePath = [path copy];
        _originalBytes = data;
        NSError *error = nil;
        NSData *json = [NSJSONSerialization dataWithJSONObject:document
            options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
        if (!json || error) return nil;
        _initialJSON = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
        if (!_initialJSON) return nil;
    }
    return self;
}
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.filePath.lastPathComponent;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Fechar" style:UIBarButtonItemStylePlain
        target:self action:@selector(fpbClose)];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"Salvar" style:UIBarButtonItemStyleDone
        target:self action:@selector(fpbSave)];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    self.navigationItem.hidesBackButton = YES;
    self.isModalInPresentation = YES;

    UITextView *editor = [[UITextView alloc] initWithFrame:CGRectZero];
    editor.translatesAutoresizingMaskIntoConstraints = NO;
    editor.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    editor.backgroundColor = UIColor.systemBackgroundColor;
    editor.textColor = UIColor.labelColor;
    editor.autocorrectionType = UITextAutocorrectionTypeNo;
    editor.autocapitalizationType = UITextAutocapitalizationTypeNone;
    editor.smartQuotesType = UITextSmartQuotesTypeNo;
    editor.smartDashesType = UITextSmartDashesTypeNo;
    editor.smartInsertDeleteType = UITextSmartInsertDeleteTypeNo;
    editor.alwaysBounceVertical = YES;
    editor.text = self.initialJSON;
    editor.delegate = self;
    self.textView = editor;
    [self.view addSubview:editor];
    UILayoutGuide *safe = self.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [editor.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:8],
        [editor.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-8],
        [editor.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [editor.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor]
    ]];
}
- (void)textViewDidChange:(UITextView *)textView {
    self.navigationItem.rightBarButtonItem.enabled =
        ![textView.text isEqualToString:self.initialJSON];
}
- (void)fpbShowError:(NSString *)title detail:(NSString *)detail {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
        message:detail preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK"
        style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)fpbFinishClose {
    [self.view endEditing:YES];
    if (self.navigationController.viewControllers.firstObject == self &&
        self.navigationController.presentingViewController) {
        [self.navigationController dismissViewControllerAnimated:YES completion:nil];
    } else if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
    } else {
        [self dismissViewControllerAnimated:YES completion:nil];
    }
}
- (void)fpbClose {
    if ([self.textView.text isEqualToString:self.initialJSON]) {
        [self fpbFinishClose]; return;
    }
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Descartar alterações?"
        message:@"O arquivo original não será modificado."
        preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Continuar editando"
        style:UIAlertActionStyleCancel handler:nil]];
    __weak typeof(self) weakSelf = self;
    [alert addAction:[UIAlertAction actionWithTitle:@"Descartar"
        style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction *action) {
            [weakSelf fpbFinishClose];
        }]];
    [self presentViewController:alert animated:YES completion:nil];
}
- (void)fpbSave {
    [self.view endEditing:YES];
    NSData *jsonData = [self.textView.text dataUsingEncoding:NSUTF8StringEncoding];
    NSError *error = nil;
    id doc = [NSJSONSerialization JSONObjectWithData:jsonData
                                             options:NSJSONReadingFragmentsAllowed error:&error];
    if (![doc isKindOfClass:NSDictionary.class]) {
        [self fpbShowError:@"JSON inválido" detail:error.localizedDescription ?: @"A raiz deve ser um objeto JSON."];
        return;
    }
    NSData *rebuilt = FPBEncode(doc, &error);
    if (!rebuilt) {
        [self fpbShowError:@"Protobuf inválido" detail:error.localizedDescription ?: @"Falha ao recompilar os campos."];
        return;
    }
    // Reject JSON edits that would not roundtrip through the exact same
    // record model. This also avoids accepting truncated/corrupt buffers.
    NSDictionary *again = FPBDecode(rebuilt, YES, &error);
    if (!again || (!!again[@"records"] != !!doc[@"records"])) {
        [self fpbShowError:@"Reconstrução rejeitada"
                  detail:error.localizedDescription ?: @"A recompilação alterou o esquema dos registros."];
        return;
    }
    if (![doc[@"records"] isKindOfClass:NSArray.class] &&
        ![doc[@"fields"] isKindOfClass:NSArray.class]) {
        [self fpbShowError:@"Formato inválido" detail:@"O JSON não possui os registros esperados."];
        return;
    }

    NSData *current = [NSData dataWithContentsOfFile:self.filePath options:0 error:&error];
    if (!current) {
        [self fpbShowError:@"Não foi possível reler o arquivo" detail:error.localizedDescription];
        return;
    }
    if (![current isEqualToData:self.originalBytes]) {
        [self fpbShowError:@"Conflito de edição"
                  detail:@"O arquivo foi alterado fora do editor. Reabre-o para evitar sobrescrever mudanças de outro processo."];
        return;
    }
    if (![rebuilt isEqualToData:current]) {
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:self.filePath error:nil];
        if (![rebuilt writeToFile:self.filePath options:NSDataWritingAtomic error:&error]) {
            [self fpbShowError:@"Falha ao salvar" detail:error.localizedDescription ?: @"O caminho não permite gravação."];
            return;
        }
        // NSFileManager's atomic replacement can replace the inode. Restore
        // the source POSIX mode when the filesystem permits it.
        NSNumber *permissions = attributes[NSFilePosixPermissions];
        if (permissions) {
            [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:permissions}
                                               ofItemAtPath:self.filePath error:nil];
        }
        NSData *verification = [NSData dataWithContentsOfFile:self.filePath options:0 error:&error];
        if (![verification isEqualToData:rebuilt]) {
            [self fpbShowError:@"Falha na verificação"
                      detail:@"A leitura após salvar não corresponde ao Protobuf compilado. Verifica o arquivo antes de continuar."];
            return;
        }
    }
    self.originalBytes = rebuilt;
    self.initialJSON = [self.textView.text copy];
    self.navigationItem.rightBarButtonItem.enabled = NO;
    FilzaDiagnosticsAppend(@"Protobuf", [NSString stringWithFormat:
        @"Saved verified Protobuf, %lu bytes, path=%@",
        (unsigned long)rebuilt.length, self.filePath.lastPathComponent]);
    [self fpbShowError:@"Salvo" detail:@"O Protobuf binário foi reconstruído e verificado. Nenhum JSON foi gravado no lugar do arquivo."];
}
@end

static IMP gFPBPreviousSelect = NULL;
static BOOL gFPBInstalled = NO;

static NSString *FPBSelectedFilePath(id controller, NSIndexPath *indexPath) {
    if (![indexPath isKindOfClass:NSIndexPath.class] || indexPath.section != 0) return nil;
    SEL listSelector = NSSelectorFromString(@"fileList");
    if (![controller respondsToSelector:listSelector]) return nil;
    id list = ((id (*)(id, SEL))objc_msgSend)(controller, listSelector);
    if (![list isKindOfClass:NSArray.class] || indexPath.row >= [list count]) return nil;
    id item = list[indexPath.row];
    SEL pathSelector = NSSelectorFromString(@"filePath");
    if (![item respondsToSelector:pathSelector]) return nil;
    id path = ((id (*)(id, SEL))objc_msgSend)(item, pathSelector);
    if ([path isKindOfClass:NSURL.class]) path = [path path];
    return [path isKindOfClass:NSString.class] ? path : nil;
}
static BOOL FPBIsCandidate(NSString *path) {
    NSString *ext = path.pathExtension.lowercaseString;
    return [@[@"pb", @"pbf", @"protobuf", @"protobin"] containsObject:ext];
}
static void FPBSelectFile(id self, SEL cmd, id browser, NSIndexPath *indexPath) {
    NSString *path = FPBSelectedFilePath(self, indexPath);
    if (path.length && [self isKindOfClass:UIViewController.class]) {
        NSError *error = nil;
        NSDictionary *attributes = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
        BOOL isRegular = [attributes[NSFileType] isEqualToString:NSFileTypeRegular];
        NSUInteger size = [attributes[NSFileSize] unsignedIntegerValue];
        if (isRegular && size > 0 && size <= 8 * 1024 * 1024) {
            NSData *bytes = [NSData dataWithContentsOfFile:path options:0 error:&error];
            if (bytes.length == size) {
                NSDictionary *document = FPBDecode(bytes, FPBIsCandidate(path), &error);
                if (document) {
                    FPBTextEditorController *editor = [[FPBTextEditorController alloc]
                        initWithPath:path bytes:bytes document:document];
                    UIViewController *source = self;
                    if (editor) {
                        if (source.navigationController) {
                            [source.navigationController pushViewController:editor animated:YES];
                        } else {
                            UINavigationController *nav = [[UINavigationController alloc]
                                initWithRootViewController:editor];
                            nav.modalPresentationStyle = UIModalPresentationPageSheet;
                            [source presentViewController:nav animated:YES completion:nil];
                        }
                        FilzaDiagnosticsAppend(@"Protobuf", [NSString stringWithFormat:
                            @"Opened normalized Protobuf: %@", path.lastPathComponent]);
                        return;
                    }
                }
            }
        }
    }
    if (gFPBPreviousSelect) {
        ((void (*)(id, SEL, id, id))gFPBPreviousSelect)(self, cmd, browser, indexPath);
    }
}
static void FPBInstallHook(void) {
    if (gFPBInstalled) return;
    Class cls = NSClassFromString(@"TGFileSystemListViewController");
    SEL selector = NSSelectorFromString(@"browserView:didSelectItemAtIndexPath:");
    Method method = cls ? class_getInstanceMethod(cls, selector) : NULL;
    if (!method || method_getNumberOfArguments(method) != 4) return;
    char returnType[8] = {0};
    method_getReturnType(method, returnType, sizeof(returnType));
    if (returnType[0] != 'v') return;
    IMP previous = method_getImplementation(method);
    if (previous == (IMP)FPBSelectFile) { gFPBInstalled = YES; return; }
    const char *types = method_getTypeEncoding(method);
    if (!class_addMethod(cls, selector, (IMP)FPBSelectFile, types)) {
        method = class_getInstanceMethod(cls, selector);
        method_setImplementation(method, (IMP)FPBSelectFile);
    }
    gFPBPreviousSelect = previous;
    gFPBInstalled = YES;
    FilzaDiagnosticsAppend(@"Protobuf", @"Installed TGFileSystemListViewController file-open hook");
}
__attribute__((constructor)) static void FPBInitialize(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        FPBInstallHook();
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
            object:nil queue:NSOperationQueue.mainQueue
            usingBlock:^(__unused NSNotification *notification) { FPBInstallHook(); }];
    });
}
