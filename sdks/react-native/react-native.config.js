// Autolinking: Android köprüsü bağlanır. iOS kapalıdır, çünkü Swift SDK yoktur (BLOCKED_EXTERNAL: macOS ve Xcode gerekir).
module.exports = {
  dependency: {
    platforms: {
      ios: null,
      android: {
        sourceDir: "./android",
        packageImportPath: "import com.feralin.reactnative.FeralinReactPackage;",
        packageInstance: "new FeralinReactPackage()",
      },
    },
  },
};
