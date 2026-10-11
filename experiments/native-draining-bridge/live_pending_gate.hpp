#pragma once
// DEV ONLY. Included solely by an explicitly macro-enabled writer build.
// Configuration is compiled, never supplied through the Lua/native protocol.
#ifndef PWP_LIVE_PENDING_GATE_DEV_ONLY
#error live_pending_gate is forbidden in the normal build
#endif
#include <Windows.h>
#include <condition_variable>
#include <chrono>
#include <mutex>
#include <string>
#include <atomic>
#include <cstdint>
namespace pwp::experimental::live_pending {
inline SRWLOCK evidence_lock=SRWLOCK_INIT;
#ifdef PWP_LIVE_PENDING_GATE_TESTING
inline std::mutex test_mutex;
inline std::condition_variable test_changed;
inline std::atomic<unsigned> test_parks=0,test_timeouts=0;
#endif
struct Gate {
    std::string scope;
    std::mutex mutex;
    std::condition_variable changed;
    bool eligible=false,used=false,parked=false,released=false,timed_out=false,join_seen=false;
    DWORD worker=0;
    bool record(const char* event,std::uint64_t accepted,std::uint64_t committed) noexcept {
        try {
            FILETIME ft;GetSystemTimePreciseAsFileTime(&ft);
            ULARGE_INTEGER utc;utc.LowPart=ft.dwLowDateTime;utc.HighPart=ft.dwHighDateTime;
            const auto line=std::string("PWP_DEV_PENDING_1\t")+std::to_string(utc.QuadPart)+"\t"+event+"\t"+scope+
                "\tworker="+std::to_string(worker)+"\tcaller="+std::to_string(GetCurrentThreadId())+
                "\taccepted="+std::to_string(accepted)+"\tcommitted="+std::to_string(committed)+
                "\tparked="+(parked?"1":"0")+"\ttimeout="+(timed_out?"1":"0")+"\n";
            AcquireSRWLockExclusive(&evidence_lock);
            HANDLE file=CreateFileW(PWP_LIVE_PENDING_EVIDENCE,FILE_APPEND_DATA,FILE_SHARE_READ,nullptr,
                OPEN_ALWAYS,FILE_ATTRIBUTE_NORMAL|FILE_FLAG_WRITE_THROUGH,nullptr);
            DWORD wrote=0;
            bool ok=file!=INVALID_HANDLE_VALUE;
            if(ok){ok=WriteFile(file,line.data(),static_cast<DWORD>(line.size()),&wrote,nullptr)!=0
                    &&wrote==line.size();ok=FlushFileBuffers(file)!=0&&ok;ok=CloseHandle(file)!=0&&ok;}
            ReleaseSRWLockExclusive(&evidence_lock);return ok;
        }catch(...){return false;}
    }
    void arm(bool existing_pair) {
        eligible=existing_pair&&(scope==PWP_LIVE_PENDING_LIMITS_SCOPE||scope==PWP_LIVE_PENDING_PRIORITIES_SCOPE);
    }
    void before_update(std::uint64_t accepted,std::uint64_t committed) {
        std::unique_lock<std::mutex> lock(mutex);
        if(!eligible||used)return;
        used=true;worker=GetCurrentThreadId();
        if(released){record("join_before_park",accepted,committed);return;}
        parked=true;
        // Start the bounded wait at update entry, never during recovery/readiness.
        const auto deadline=std::chrono::steady_clock::now()+std::chrono::milliseconds(
#ifdef PWP_LIVE_PENDING_GATE_TESTING
            PWP_LIVE_PENDING_TEST_TIMEOUT_MS
#else
            60000
#endif
        );
        if(!record("park",accepted,committed)){parked=false;released=true;return;}
#ifdef PWP_LIVE_PENDING_GATE_TESTING
        {std::lock_guard<std::mutex> test_lock(test_mutex);++test_parks;test_changed.notify_all();}
#endif
        if(!changed.wait_until(lock,deadline,[&]{return released;})){
            timed_out=true;released=true;record("timeout",accepted,committed);
#ifdef PWP_LIVE_PENDING_GATE_TESTING
            {std::lock_guard<std::mutex> test_lock(test_mutex);++test_timeouts;test_changed.notify_all();}
#endif
        }
        record(timed_out?"release_timeout":"release_join",accepted,committed);parked=false;
    }
    void before_join(std::uint64_t accepted,std::uint64_t committed) {
        std::lock_guard<std::mutex> lock(mutex);
        if(!eligible||join_seen)return;
        join_seen=true;
        // Only a parked, non-timeout record with accepted>committed qualifies.
        record("join",accepted,committed);released=true;changed.notify_all();
    }
};
}
