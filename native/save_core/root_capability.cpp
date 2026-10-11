#include "root_capability.hpp"
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <Windows.h>
#include <mutex>
#include <utility>

namespace pwp::experimental {
namespace {
// Survive arbitrary static destruction order of callers' shared_ptr captures.
// One permanently bounded registry, not a growing retained-object collection.
std::mutex& gate=*new std::mutex;
RootRelease& lifecycle=*new RootRelease{RootLifetime::unconfigured, 0};
int module_anchor=0;
constexpr std::size_t max_pins = 64;
#ifdef PWP_ROOT_CAPABILITY_TESTING
// Test executable only. Returns an injected error BEFORE a real close; keeps
// that actual handle open to exercise bounded retention without invalid handles.
extern "C" DWORD pwp_root_test_close_error() noexcept;
#endif
DWORD checked_close(HANDLE handle) noexcept {
#ifdef PWP_ROOT_CAPABILITY_TESTING
    if (const auto e = pwp_root_test_close_error()) return e;
#endif
    if (CloseHandle(handle)) return 0;
    const auto e = GetLastError();
    return e ? e : ERROR_GEN_FAILURE;
}
bool valid_root(const std::wstring& root) {
    if (root.size()<4 || root.size()>140 || root[1]!=L':' || root[2]!=L'\\' || root.back()==L'\\'
        || !((root[0]>=L'A' && root[0]<=L'Z') || (root[0]>=L'a' && root[0]<=L'z'))) return false;
    std::size_t count=1;
    for (std::size_t start=3; start<root.size();) {
        auto end=root.find(L'\\',start);if(end==std::wstring::npos)end=root.size();
        const auto part=root.substr(start,end-start);
        if (++count>max_pins || part.empty() || part==L"." || part==L".."
            || part.back()==L'.' || part.back()==L' ' || part.find_first_of(L"/:*?\"<>|")!=std::wstring::npos) return false;
        for (auto c:part) if(c<32)return false;
        start=end+1;
    }
    return true;
}
}
RootCapability::RootCapability(std::wstring root,std::string profile_namespace)
    :root_(std::move(root)),profile_namespace_(std::move(profile_namespace)) {}
RootCapability::~RootCapability() noexcept {
    DWORD error=0;
    for(auto it=pins_.rbegin();it!=pins_.rend();++it) {
        const auto handle=std::exchange(*it,nullptr);
        if(handle && (error=checked_close(handle))!=0) break;
    }
    // Remaining raw handle values intentionally have no retrying destructors.
    // One configuration attempt bounds this retention, even on partial failure.
    std::lock_guard<std::mutex> lock(gate);
    lifecycle={error ? RootLifetime::uncertain : RootLifetime::released,error};
}
std::shared_ptr<const RootCapability> RootCapability::open(std::wstring root,
                                                        std::string profile_namespace) noexcept {
    std::uint32_t error=0;
    {
        std::lock_guard<std::mutex> lock(gate);
        if(lifecycle.state!=RootLifetime::unconfigured) return {};
        lifecycle={RootLifetime::configuring,0};
    }
    std::shared_ptr<RootCapability> cap;
    try {
        bool label_ok=!profile_namespace.empty() && profile_namespace.size()<=64
            && profile_namespace[0]>='a' && profile_namespace[0]<='z';
        for(auto c:profile_namespace) if(!((c>='a'&&c<='z')||(c>='0'&&c<='9')||c=='-')) label_ok=false;
        if(!valid_root(root) || !label_ok) error=ERROR_INVALID_NAME;
        else if(GetDriveTypeW(root.substr(0,3).c_str())!=DRIVE_FIXED) error=ERROR_NOT_SUPPORTED;
        if(!error) {
            HMODULE module=nullptr;
            if(!GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS|GET_MODULE_HANDLE_EX_FLAG_PIN,
                reinterpret_cast<LPCWSTR>(&module_anchor),&module)) error=GetLastError();
        }
        if(!error) {
            cap=std::shared_ptr<RootCapability>(new RootCapability(root,std::move(profile_namespace)));
            cap->pins_.reserve(max_pins); // no allocation after an open handle
            for(std::size_t end=2;;) {
                const auto path=root.substr(0,end+(end==2?1:0));
                // Metadata-only opens do not participate in delete sharing on
                // Windows. Directory-list (read-data) access makes these pins
                // actually deny ordinary directory replacement/rename.
                const auto h=CreateFileW(path.c_str(),FILE_LIST_DIRECTORY|FILE_READ_ATTRIBUTES,FILE_SHARE_READ|FILE_SHARE_WRITE,
                    nullptr,OPEN_EXISTING,FILE_FLAG_BACKUP_SEMANTICS|FILE_FLAG_OPEN_REPARSE_POINT,nullptr);
                if(h==INVALID_HANDLE_VALUE) {error=GetLastError();break;}
                cap->pins_.push_back(h);
                FILE_ATTRIBUTE_TAG_INFO attrs{};
                if(!GetFileInformationByHandleEx(h,FileAttributeTagInfo,&attrs,sizeof(attrs))) {error=GetLastError();break;}
                if(!(attrs.FileAttributes&FILE_ATTRIBUTE_DIRECTORY) || (attrs.FileAttributes&FILE_ATTRIBUTE_REPARSE_POINT)) {
                    error=ERROR_NOT_SUPPORTED;break;
                }
                if(end==root.size()) {
                    FILE_ID_INFO id{};
                    if(!GetFileInformationByHandleEx(h,FileIdInfo,&id,sizeof(id))) {error=GetLastError();break;}
                    cap->identity_.volume=id.VolumeSerialNumber;
                    for(std::size_t i=0;i<16;++i)cap->identity_.file_id[i]=id.FileId.Identifier[i];
                    break;
                }
                end=root.find(L'\\',end==2?3:end+1);
                if(end==std::wstring::npos)end=root.size();
            }
        }
    } catch(...) {error=ERROR_UNHANDLED_EXCEPTION;}
    if(error) {
        cap.reset(); // checked cleanup; a close error must not become retryable
        std::lock_guard<std::mutex> lock(gate);
        if(lifecycle.state==RootLifetime::uncertain) error=lifecycle.error;
        else lifecycle={RootLifetime::rejected,error};
        return {};
    }
    {
        std::lock_guard<std::mutex> lock(gate);
        // Retirement during construction cancels publication of the capability.
        if(lifecycle.state!=RootLifetime::configuring) error=ERROR_OPERATION_ABORTED;
        else lifecycle={RootLifetime::live,0};
    }
    if(error) {cap.reset();return {};}
    return cap;
}
RootRelease RootCapability::retire() noexcept {
    std::lock_guard<std::mutex> lock(gate);
    if(lifecycle.state==RootLifetime::live || lifecycle.state==RootLifetime::configuring
        || lifecycle.state==RootLifetime::unconfigured) lifecycle.state=RootLifetime::retiring;
    return lifecycle;
}
RootRelease RootCapability::release_status() noexcept {
    std::lock_guard<std::mutex> lock(gate);return lifecycle;
}
}
