// FERALIN_TRANSPORT=NONE: HTTP katmanı derlenmez; gömülü sistemler Options::transport veya feralin_options.transport verir.
#include "feralin/feralin.hpp"

namespace feralin {

std::shared_ptr<Transport> default_transport() { return nullptr; }

}  // namespace feralin
