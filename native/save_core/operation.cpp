#include "operation.hpp"
#include <utility>
namespace pwp::experimental {
SaveOperation::SaveOperation(std::shared_ptr<SaveOwner> o,OwnerBinding b,
 std::uint64_t t,std::wstring r,std::wstring s,std::wstring g,std::wstring k,
 journal::Preimages p,std::string bytes):owner(std::move(o)),binding(std::move(b)),
 ticket(t),root(std::move(r)),storage(std::move(s)),guild(std::move(g)),
 stream(std::move(k)),expected(std::move(p)),encoded(std::move(bytes)){}
std::shared_ptr<SaveOperation> SaveOperation::admit(std::shared_ptr<SaveOwner> o,
 OwnerBinding b,std::uint64_t t,std::wstring r,std::wstring s,std::wstring g,
 std::wstring k,journal::Preimages p,std::string bytes) {
    if(!o || r.empty() || r.size()>32767) return {};
    // Require canonical ASCII scope components, so the owner scope and file
    // namespace cannot disagree through conversion, case or hidden suffixes.
    const auto guid=[](const std::wstring& v) {
        if(v.size()!=32 || v==std::wstring(32,L'0')) return false;
        for(auto c:v) if(!((c>=L'0'&&c<=L'9')||(c>=L'a'&&c<=L'f'))) return false;
        return true;
    };
    if(!guid(s)||!guid(g)||(k!=L"priorities"&&k!=L"limits")) return {};
    const auto ascii=[](const std::wstring& v) {std::string a;for(auto c:v)a+=static_cast<char>(c);return a;};
    const std::string scope="PWP-SCOPE-1:"+ascii(s)+":"+ascii(g)+":"+ascii(k);
    if(scope!=b.scope || records::decode(bytes,scope).state!=records::State::valid) return {};
    for(const auto& v:p) if(v && v->size()>records::max_record) return {};
    // All allocation/copying precedes reservation. A failed allocation cannot
    // strand a claimed ticket that no operation object can ever complete.
    auto op=std::shared_ptr<SaveOperation>(new SaveOperation(o,std::move(b),t,
        std::move(r),std::move(s),std::move(g),std::move(k),std::move(p),std::move(bytes)));
    if(!o->reserve(op->binding,t)) return {};
    return op;
}
bool SaveOperation::run() noexcept {
    if(started.exchange(true)) return false;
    try {
        if(owner->retired()) return owner->complete(ticket,true,"cancelled-before-io");
        const auto r=journal::update(root,storage,guild,stream,expected,encoded);
        const char* name="uncertain";
        switch(r.status) {
        case journal::Status::initialized:name="initialized";break;
        case journal::Status::updated:name="updated";break;
        case journal::Status::conflict:name="conflict";break;
        case journal::Status::io_error:name="io-error";break;
        case journal::Status::uncertain:break;
        }
        auto result=std::string(name)+":"+std::to_string(r.error)+":"+
            r.slot+":"+std::to_string(r.generation);
        // Additive diagnostic only: cleanup failure must not turn an already
        // published update into a retryable IO error. Normal results unchanged.
        if(r.cleanup_error) result+=":cleanup-error="+std::to_string(r.cleanup_error);
        return owner->complete(ticket,r.status!=journal::Status::uncertain,result);
    } catch(...) {
        // Retaining an unresolved claim is safer than reopening a writer after
        // an allocation/transport failure. Never replace the original owner.
        try {owner->complete(ticket,false,"operation-exception");} catch(...) {}
        return false;
    }
}
}
